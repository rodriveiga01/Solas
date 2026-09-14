import AppKit
import SwiftUI
import Carbon
import ApplicationServices

// MARK: - Entry

@main
struct SolasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Launcher panel

/// Borderless floating card (the Spotlight/Raycast recipe): no titlebar
/// means no traffic-light overlap and no titlebar-height mismatch — the
/// content measures exactly what the panel shows. Key-capable so the
/// field takes real focus; Esc / toggle hides it, hiding never clears.
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that keeps the panel fitted to the card. Fires after
/// layout completes (async hop breaks reentrancy); the <1pt guard in
/// the fitter breaks feedback. No GeometryReader preferences — measured
/// headlessly, they report 0 for scroll-containing trees while
/// fittingSize computes the exact ideal height.
final class FitHostingView: NSHostingView<ContentView> {
    weak var app: AppDelegate?
    override func layout() {
        super.layout()
        DispatchQueue.main.async { [weak self] in
            self?.app?.fitPanelToFittingSize()
        }
    }
}

// MARK: - AppDelegate: menu bar, hotkeys, floating card

/// The card stays visible for the whole ask: type → inline spinner →
/// inline answer/error. Hiding never clears (answers survive hide and
/// app switches; Esc on a finished answer clears it). That removes the
/// old hide-then-pop race where a run could finish with nothing visible
/// and read as "no result".
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ObservableObject {
    /// Shown in the footer when hotkeys are degraded. Nil = all good.
    @Published var hotkeyNote: String?
    /// Accessibility capture (monitor + tap tiers). Updated on every summon.
    @Published var axTrusted = false

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var panel: NSPanel?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var registeredIDs = Set<Int>()
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyUPP: EventHandlerUPP?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hidTap: CFMachPort?
    private var hidRunLoopSource: CFRunLoopSource?
    private var lastToggle = Date.distantPast
    private let lastFireKey = "Solas.lastHotkeyFire"
    /// Last time any tier actually fired (persisted — proof across restarts).
    var lastFire: Date? { UserDefaults.standard.object(forKey: lastFireKey) as? Date }
    var lastFireDescription: String {
        guard let d = lastFire else { return "never" }
        return ISO8601DateFormatter().string(from: d)
    }
    private static let axPromptKey = "Solas.didPromptAX"
    private(set) var thinking = false
    private let runner = OpencodeRunner()
    private let models = ModelStore()

    private static let panelWidth: CGFloat = 540

    // kVK_Space = 49. Carbon masks: shiftKey = 512, controlKey = 4096.
    // ONE hotkey, deliberately: ⇧⌃Space produces no text, macOS claims
    // nothing like it (unlike ⌘Space = Spotlight, ⌥Space = nbsp in
    // fields), and no launcher uses it. ⌘Space is never touched.
    private static let hotKeys = [
        (id: 3, keyCode: 49, modifiers: 4096 | 512, name: "⇧⌃Space"),
    ]
    private static let hotKeyExistsErr: OSStatus = -9878

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        takeOverFromStaleInstances()
        setupMenuBar()
        setupPanel()
        installHotKeyHandlerFirst()
        registerHotKeys()
        registerLocalFallback()
        registerTrustedMonitor()
        registerHIDTap()
        refreshAXTrust() // silent check only — the prompt is user-initiated
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let owned = Self.hotKeys.filter { registeredIDs.contains($0.id) }.map(\.name).joined(separator: ",")
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        SolasLog.log("Solas launched build=\(BuildInfo.tag) pid=\(pid) path=\(path) os=\(os) hotkeys-owned=[\(owned)] secureInput=\(secureInputOn()) axTrusted=\(axTrusted) tap=\(tapStatus())")
        // Stale instances release hotkeys asynchronously — retry on a
        // lengthening schedule, not just once.
        for delay in [2.0, 6.0, 12.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.retryMissingHotKeys()
            }
        }
        // Eternal self-heal: if the combo is ever lost later (a duplicate
        // launched first and died, a race at login), re-grab it within a
        // minute — no relaunch, no menu summon required. Silent when owned.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.retryMissingHotKeys()
                self?.registerTrustedMonitor() // no-op unless tap is nil
                self?.registerHIDTap() // no-op unless tap is nil
            }
        }
        Task { await models.refresh() }
        showPanel() // proof of life: the card greets on every launch
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning to the app is another chance to heal an orphaned hotkey.
        retryMissingHotKeys()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Spotlight-by-name summon: typing "Solas" in Spotlight and hitting
        // Enter relaunches/focuses us — bring the card forward every time.
        // (The only Spotlight integration Apple allows: launch by name.)
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs = []
        registeredIDs = []
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
        eventHandlerRef = nil
        hotKeyUPP = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if let tap = hidTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = hidRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        hidTap = nil
        hidRunLoopSource = nil
    }

    // MARK: Menu bar — left-click toggles instantly, right-click opens menu

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Solas")
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(statusClicked(_:))
        button.target = self

        let menu = NSMenu()
        menu.delegate = self
        let explainItem = NSMenuItem(title: "Explain a concept…", action: #selector(showFromMenu(_:)), keyEquivalent: "")
        explainItem.target = self
        menu.addItem(explainItem)
        let modelItem = NSMenuItem(title: "Choose model…", action: #selector(pickModel(_:)), keyEquivalent: "")
        modelItem.target = self
        menu.addItem(modelItem)
        let hkItem = NSMenuItem(title: "Keyboard Shortcut…", action: #selector(showHotkeyHelp(_:)), keyEquivalent: "")
        hkItem.target = self
        menu.addItem(hkItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Solas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        self.statusMenu = menu
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let menu = statusMenu {
            statusItem?.menu = menu
            sender.performClick(nil)
        } else {
            togglePanel()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if statusItem?.menu === menu { statusItem?.menu = nil }
    }

    @objc private func showFromMenu(_ sender: Any?) {
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .solasFocusInput, object: nil)
        } else {
            showPanel()
        }
    }

    @objc private func pickModel(_ sender: Any?) {
        showPanel(reset: false)
        NotificationCenter.default.post(name: .solasShowModels, object: nil)
    }

    @objc private func showHotkeyHelp(_ sender: Any?) {
        showPanel(reset: false)
        NotificationCenter.default.post(name: .solasShowHotkeys, object: nil)
    }

    // MARK: Thinking state (drives the menu icon only)

    func setThinking(_ t: Bool) {
        thinking = t
        statusItem?.button?.image = NSImage(
            systemSymbolName: t ? "sparkles" : "sparkle.magnifyingglass",
            accessibilityDescription: "Solas"
        )
    }

    func cancelSolas() {
        runner.cancelCurrent()
    }

    // MARK: Floating card — borderless launcher panel (see CardPanel)

    private func setupPanel() {
        let runner = self.runner
        let models = self.models
        let content = ContentView(
            app: self,
            models: models,
            onSolas: { question, model in try await runner.ask(question, model: model) },
            onClose: { [weak self] in self?.hidePanel() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hosting = FitHostingView(rootView: content)
        hosting.app = self

        let p = CardPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.contentView = hosting
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        // Sticky card: switching apps never dismisses it — read the answer
        // while you work elsewhere. Esc / toggle hides it; hiding never
        // clears anything (clearing is Esc on a finished answer).
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // the SwiftUI card draws its own shadow
        anchorTopCenter(p, height: 240)
        self.panel = p
    }

    /// Spotlight placement: centered horizontally, top edge parked in the
    /// upper third. Growth goes downward — the input row never moves.
    private static func topEdge(_ vf: CGRect) -> CGFloat {
        vf.maxY - max(120, vf.height * 0.24)
    }

    private func anchorTopCenter(_ p: NSPanel, height: CGFloat) {
        guard let screen = NSScreen.main else { p.center(); return }
        let vf = screen.visibleFrame
        let w = min(Self.panelWidth, vf.width - 40)
        let h = min(height, vf.height - 60)
        p.setFrame(NSRect(x: vf.midX - w / 2, y: Self.topEdge(vf) - h, width: w, height: h), display: false)
    }

    /// Sizes the panel to the card's true ideal height, top-anchored so
    /// the input stays put and the card grows downward with the response.
    /// Driven by layout itself — every state change refits with no call
    /// sites to maintain and no measurement feedback loops. Tracks the
    /// in-flight target so animation frames don't restart the animation
    /// (and don't spam the log into rotation).
    private var lastFitTarget: CGFloat = -1
    @objc func fitPanelToFittingSize() {
        guard let panel, let hosting = panel.contentView as? FitHostingView,
              let screen = NSScreen.main, panel.isVisible else { return }
        let ideal = hosting.fittingSize.height
        guard ideal > 0 else { return }
        let vf = screen.visibleFrame
        let target = min(max(ideal, 150), 720, vf.height - 60)
        var f = panel.frame
        if abs(f.height - target) < 1 { lastFitTarget = target; return }
        if target == lastFitTarget { return } // already flying there
        lastFitTarget = target
        f.size.height = target
        f.size.width = min(Self.panelWidth, vf.width - 40)
        f.origin.x = vf.midX - f.width / 2
        f.origin.y = Self.topEdge(vf) - f.height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().setFrame(f, display: true)
        }
    }

    var isPanelVisible: Bool { panel?.isVisible == true }

    @objc func togglePanel() {
        guard let panel else { return }
        // Dedup: Carbon + monitor + tap race — arrivals inside 250ms are
        // echoes of one press, not intent.
        let now = Date()
        if now.timeIntervalSince(lastToggle) < 0.25 { return }
        lastToggle = now
        SolasLog.log("toggle (visible=\(panel.isVisible) thinking=\(thinking) front=\(frontID()) secureInput=\(secureInputOn()))")
        panel.isVisible ? hidePanel() : showPanel()
    }

    // MARK: Hotkey observability — every tier funnels through here

    /// Single funnel for all three tiers. Records the firing (persisted —
    /// the help card's "last received" is proof across restarts), logs it,
    /// then toggles (dedup collapses tier echoes).
    func hotkeyFired(source: String, detail: String) {
        UserDefaults.standard.set(Date(), forKey: lastFireKey)
        SolasLog.log("hotkey fired → toggle (\(source) \(detail))")
        togglePanel()
    }

    func frontID() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    }

    func secureInputOn() -> Bool { IsSecureEventInputEnabled() }

    func tapStatus() -> String { hidTap == nil ? "INACTIVE" : "active" }

    /// Builds the paste-ready diagnostics block (status + log tail) and
    /// copies it. The tail is what determines the culprit: per-press lines
    /// (source + flags + front app) versus true silence.
    func copyDiagnostics() {
        let owned = Self.hotKeys.filter { registeredIDs.contains($0.id) }.map(\.name).joined(separator: ",")
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        var s = "Solas diagnostics build=\(BuildInfo.tag)\n"
        s += "hotkey-owned: \(owned.isEmpty ? "(none)" : owned)\n"
        s += "last-fire: \(lastFireDescription)\n"
        s += "ax-trusted: \(axTrusted)\n"
        s += "secure-input: \(secureInputOn())\n"
        s += "tap: \(tapStatus())\n"
        s += "pid: \(pid)\n"
        s += "path: \(path)\n"
        s += "\n--- log tail ---\n"
        s += Self.logTail(lines: 40)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        SolasLog.log("diagnostics copied")
    }

    private static func logTail(lines: Int) -> String {
        guard let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Solas.log"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return "(no log)" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    func showPanel(reset: Bool = false) {
        guard let panel else { return }
        refreshAXTrust()
        registerHIDTap() // self-heal a tap lost to timeout/invalidation
        retryMissingHotKeys() // anything released since launch? grab it now
        NSApp.unhide(nil)
        anchorTopCenter(panel, height: panel.frame.height)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak panel] in
                // Insurance: an interrupted fade must never leave the card
                // transparent — a visible window at alpha 0 reads as "dead".
                DispatchQueue.main.async { panel?.alphaValue = 1 }
            })
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Sticky card: showing never clears. A finished answer survives
        // hides and app switches; Esc on a finished answer clears it.
        // The reset flag is kept for explicit programmatic resets only.
        if reset {
            NotificationCenter.default.post(name: .solasReset, object: nil)
        }
        NotificationCenter.default.post(name: .solasFocusInput, object: nil)
    }

    /// Hiding never clears — answers survive hide, switch, and reopen.
    func hidePanel() {
        panel?.orderOut(nil)
        NSApp.hide(nil)
    }

    // MARK: Hotkeys — tier 1 Carbon (permission-free), tier 2 Accessibility

    /// Tier 1: Carbon RegisterEventHotKey is still the only public API for
    /// global hotkeys without Accessibility permission (the same API the
    /// industry-standard KeyboardShortcuts package uses — App Store safe).
    /// Tier 2 (below) covers whatever Carbon can't deliver, once the user
    /// explicitly enables it.
    private func installHotKeyHandlerFirst() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let upp: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.hotkeyFired(source: "carbon", detail: "id=3")
            }
            return noErr
        }
        self.hotKeyUPP = upp
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), upp, 1, &spec, nil, &ref)
        if status != noErr {
            SolasLog.log("hotkey handler install failed (\(status)) — hotkeys will not fire")
        } else {
            eventHandlerRef = ref
        }
    }

    private func registerHotKeys() {
        for hk in Self.hotKeys {
            _ = registerHotKey(keyCode: hk.keyCode, modifiers: hk.modifiers, id: hk.id)
        }
        updateHotkeyNote()
    }

    private func registerHotKey(keyCode: Int, modifiers: Int, id: Int) -> Bool {
        if registeredIDs.contains(id) { return true }
        let hotKeyID = EventHotKeyID(signature: OSType(0x534F4C21), id: UInt32(id)) // "SOL!"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            if status == Self.hotKeyExistsErr {
                SolasLog.log("hotkey id \(id) held by another process (stale Solas?)")
            } else {
                SolasLog.log("hotkey id \(id) registration failed (\(status))")
            }
            return false
        }
        hotKeyRefs.append(ref)
        registeredIDs.insert(id)
        return true
    }

    /// Kills stale copies of Solas so this instance owns the hotkeys.
    /// Same Carbon signature is global: whoever holds it blocks us.
    /// Spares only an identified *different* product sharing the name;
    /// dev binaries (nil bundle id) always fight for the same combos.
    private func takeOverFromStaleInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != me else { continue }
            let name = app.localizedName ?? ""
            let exec = app.executableURL?.lastPathComponent ?? ""
            guard name == "Solas" || exec == "Solas" else { continue }
            // Same Carbon signature is global: whoever holds it blocks us.
            // Spare only an identified *different* product; dev binaries
            // (nil bundle id) always fight for the same combos.
            if let myID = Bundle.main.bundleIdentifier,
               let otherID = app.bundleIdentifier,
               myID != otherID { continue }
            SolasLog.log("terminating stale instance pid \(app.processIdentifier)")
            app.terminate()
            let pid = app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let stale = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
                   !stale.isTerminated {
                    stale.forceTerminate()
                }
            }
        }
    }

    /// Retries anything unregistered (released stale hold, freed combo).
    /// Cheap when everything is owned — safe to call on every summon.
    private func retryMissingHotKeys() {
        let missing = Self.hotKeys.filter { !registeredIDs.contains($0.id) }
        guard !missing.isEmpty else { return }
        for hk in missing {
            _ = registerHotKey(keyCode: hk.keyCode, modifiers: hk.modifiers, id: hk.id)
        }
        updateHotkeyNote()
    }

    private func updateHotkeyNote() {
        let missing = Self.hotKeys.filter { !registeredIDs.contains($0.id) }
        hotkeyNote = missing.isEmpty ? nil : "Shortcut unavailable — details"
    }

    /// In-app fallback while Solas is frontmost: catch the hotkey locally
    /// and swallow it. Superset match tolerates stowaway flags (caps lock,
    /// fn, driver-added bits); global monitors never see own-app events,
    /// so this path owns presses made while Solas is focused.
    private func registerLocalFallback() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains([.control, .shift]) else { return event }
            let detail = String(format: "flags=0x%lX", event.modifierFlags.rawValue)
            DispatchQueue.main.async { self?.hotkeyFired(source: "local", detail: detail) }
            return nil
        }
    }

    /// Tier 2: system-wide key monitor. Creation is VERIFIED (a nil tap
    /// fails silently — the worst kind of dead), and retried while nil.
    /// Every Space+modifier press is logged (plain Space skipped — too
    /// noisy); the hotkey funnels through hotkeyFired. Always fires — the
    /// 250ms toggle dedup collapses Carbon+monitor+tap echoes, so no gate
    /// that could suppress a Carbon gap.
    private func registerTrustedMonitor() {
        guard globalMonitor == nil else { return }
        guard let tap = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 49 else { return }
            let mods = event.modifierFlags.intersection([.control, .shift, .option, .command])
            guard !mods.isEmpty else { return } // plain Space: pass silently
            let detail = String(format: "flags=0x%lX front=%@", event.modifierFlags.rawValue, self?.frontID() ?? "?")
            SolasLog.log("space-monitor \(detail)")
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains([.control, .shift]) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.hotkeyFired(source: "monitor", detail: detail)
            }
        }) else {
            SolasLog.log("global monitor creation FAILED (nil) — will retry")
            return
        }
        globalMonitor = tap
    }

    /// Tier 3: session event tap, pre-dispatch. Carbon fires only when the
    /// frontmost app reports the key unhandled — self-drawn editors/terms
    /// (Zed, VS Code, Electron, JetBrains) consume everything, so Carbon
    /// goes silently deaf there. NSEvent monitors can't swallow. The tap
    /// sees the key before dispatch, fires anywhere, and swallows only the
    /// exact hotkey. Needs the AX grant (creation returns nil without it —
    /// that nil IS the datum: logged, retried on grant and every 60s).
    /// The 250ms toggle dedup collapses tap+Carbon+monitor echoes.
    private func registerHIDTap() {
        guard hidTap == nil else { return }
        guard axTrusted else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: solasTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            SolasLog.log("hid tap creation FAILED (nil) — grant Input Monitoring + Accessibility, then relaunch")
            return
        }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            SolasLog.log("hid tap source FAILED — will retry")
            CFMachPortInvalidate(tap)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        hidTap = tap
        hidRunLoopSource = src
        SolasLog.log("hid tap active — pre-dispatch capture on")
    }

    /// Re-enables a tap the system parked for slow processing, or rebuilds
    /// one that died. Called from the tap callback via the main actor.
    func reenableHIDTap() {
        if let tap = hidTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            registerHIDTap()
        }
    }

    // MARK: Accessibility permission (explicit-action only, never at launch)

    /// Cheap synchronous trust check; refreshes the published flag so the
    /// help card and menu status stay honest. If trust just arrived, the
    /// old monitor was born dead (taps don't retro-activate) — rebuild it
    /// under the grant immediately.
    func refreshAXTrust() {
        let now = AXIsProcessTrusted()
        guard now != axTrusted else { return }
        axTrusted = now
        if now {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            globalMonitor = nil
            registerTrustedMonitor()
            registerHIDTap()
            SolasLog.log("AX granted — monitor rebuilt under trust tap=\(tapStatus())")
        } else {
            SolasLog.log("AX revoked — tap/monitor degraded")
        }
    }

    /// Called ONLY from the shortcut card's button (Apple guidance: the system
    /// prompt appears once per app identity — never spend it on a timer or
    /// at launch). First call shows the native prompt; later calls open
    /// System Settings, since a spent prompt shows no UI at all.
    func requestAXPermission() {
        if !UserDefaults.standard.bool(forKey: Self.axPromptKey) {
            UserDefaults.standard.set(true, forKey: Self.axPromptKey)
            // Key literal avoids the non-Sendable Carbon global in Swift 6.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Re-check shortly: the user may grant and return.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshAXTrust()
        }
    }
}

extension Notification.Name {
    static let solasFocusInput = Notification.Name("solasFocusInput")
    static let solasShowModels = Notification.Name("solasShowModels")
    static let solasShowHotkeys = Notification.Name("solasShowHotkeys")
    static let solasReset = Notification.Name("solasReset")
}

// MARK: - Pre-dispatch tap callback (C function: no captures, no actor)

/// Session-tap callback for tier 3. Synchronous part stays pure (code +
/// flags only) so the swallow decision is instant; everything touching the
/// app hops to the main actor. Never reads key characters — codes only.
private func solasTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout {
        if let refcon {
            let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in app.reenableHIDTap() }
        }
        return Unmanaged.passRetained(event)
    }
    guard type == .keyDown else { return Unmanaged.passRetained(event) }
    guard event.getIntegerValueField(.keyboardEventKeycode) == 49 else {
        return Unmanaged.passRetained(event)
    }
    let mods = event.flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand])
    guard !mods.isEmpty else { return Unmanaged.passRetained(event) } // plain Space: pass silently
    let hot = event.flags.contains([.maskControl, .maskShift])
    if let refcon {
        let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
        let flagsRaw = event.flags.rawValue
        Task { @MainActor in
            let detail = String(format: "flags=0x%llX front=%@", flagsRaw, app.frontID())
            SolasLog.log("space-tap \(detail)")
            if hot { app.hotkeyFired(source: "tap", detail: detail) }
        }
    }
    return hot ? nil : Unmanaged.passRetained(event) // swallow only the hotkey
}
