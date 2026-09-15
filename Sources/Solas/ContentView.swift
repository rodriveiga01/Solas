import AppKit
import SwiftUI

/// Spotlight-class explainer card: type → inline spinner → inline
/// answer/error. Hiding (toggle, ×, Esc on idle) never clears — Esc on a
/// finished answer clears it back to blank.
struct ContentView: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var models: ModelStore
    let onSolas: (String, String?) async throws -> String
    let onClose: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var question = ""
    @State private var answer = ""
    @State private var isLoading = false
    @State private var loadingQuestion = ""
    @State private var errorText = ""
    @State private var showModels = false
    @State private var showShortcut = false
    @State private var copied = false
    @State private var loadingPulse = false
    @State private var hoveredRow: Int?
    @State private var hoveredModel: String?
    @FocusState private var inputFocused: Bool

    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    private var canRetry: Bool {
        !isLoading && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var cardStroke: Color {
        if !answer.isEmpty,
           let first = AnswerParser.accentNames(in: answer).first,
           let c = AccentColors.color(first, scheme) {
            return c.opacity(0.45)
        }
        return .white.opacity(0.16)
    }

    var body: some View {
        Group {
            if app.isParked {
                ParkedPillView(
                    question: app.parkedQuestion.isEmpty ? loadingQuestion : app.parkedQuestion,
                    isReady: app.parkedReady,
                    hasError: app.parkedHasError,
                    onPeek: {
                        app.unparkToCenter(source: app.parkedReady ? "unpark-ready-click" : "peek-pill-click")
                    }
                )
                .frame(height: 40)
                .transition(.opacity)
            } else {
                fullCard
                    .transition(.opacity)
            }
        }
        // Content crossfades on a snappy spring while the panel frame
        // flies on its own spring in AppKit; Reduce Motion collapses the
        // swap to an instant cut.
        .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: app.isParked)
    }

    private var fullCard: some View {
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                inputRow
                if isLoading {
                    Divider().padding(.horizontal, 20)
                    thinkingRow
                } else if showShortcut {
                    Divider().padding(.horizontal, 20)
                    shortcutCard
                } else if showModels || models.shouldForcePicker {
                    Divider().padding(.horizontal, 20)
                    modelPicker(firstRun: models.needsSelection)
                } else if !errorText.isEmpty {
                    Divider().padding(.horizontal, 20)
                    errorView
                } else if !answer.isEmpty {
                    Divider().padding(.horizontal, 20)
                    answerView
                } else {
                    Divider().padding(.horizontal, 20)
                    idleView
                }
                footer()
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(cardStroke, lineWidth: 1)
            )
        }
        .padding(20)
        .frame(width: 540)
        .onReceive(NotificationCenter.default.publisher(for: .solasReset)) { _ in reset() }
        .onReceive(NotificationCenter.default.publisher(for: .solasFocusInput)) { _ in
            // Ready answers own the card — don't yank focus back to the
            // field when expanding to a finished result.
            if !isLoading, answer.isEmpty, errorText.isEmpty { inputFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .solasShowModels)) { _ in
            if !isLoading { showModels = true; showShortcut = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .solasShowHotkeys)) { _ in
            if !isLoading { showShortcut = true }
        }
        .onAppear { inputFocused = true }
        .onExitCommand { handleEscape() }
    }

    private func reset() {
        guard !isLoading else { return }
        question = ""
        answer = ""
        errorText = ""
        copied = false
        loadingQuestion = ""
        showModels = false
        showShortcut = false
        app.setHasUnclearedResult(false)
    }

    private func handleEscape() {
        if isLoading {
            app.cancelSolas()
        } else if showShortcut {
            showShortcut = false
            inputFocused = true
        } else if showModels {
            showModels = false
            inputFocused = true
        } else if !answer.isEmpty || !errorText.isEmpty {
            // Sticky card: Esc clears the finished result to a blank card
            // (hiding via toggle/× never clears).
            answer = ""
            errorText = ""
            copied = false
            app.setHasUnclearedResult(false)
            inputFocused = true
        } else {
            onClose()
        }
    }

    // MARK: - Keycap

    /// Apple-style keycap chip for shortcut hints.
    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
    }

    // MARK: - Input (always visible; disabled only while thinking)

    private var inputRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            TextField("Explain anything — try “gravity”", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($inputFocused)
                .onSubmit(submit)
                .submitLabel(.go)
                .disabled(isLoading)
                .accessibilityLabel("Question")
                .accessibilityHint("Type a concept or question, then press Return to explain")

            if isLoading {
                Button("Cancel") { app.cancelSolas() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.7), in: Capsule())
            } else if !question.isEmpty {
                Button {
                    question = ""
                    inputFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear question")

                Button { submit() } label: {
                    Image(systemName: "return")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(canSubmit ? .white : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            canSubmit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityLabel("Explain")
                .accessibilityHint("Explains the typed concept or question")
            }

            Divider()
                .frame(height: 18)

            Button {
                if isLoading { app.cancelSolas() }
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityHint("Hides the card. Your answer stays for when you come back.")
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(inputFocused ? 0.4 : 0), lineWidth: 2)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .animation(.easeOut(duration: 0.18), value: inputFocused)
        )
    }

    // MARK: - Thinking (inline — the card stays put)

    private var thinkingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Explaining “\(preview(of: loadingQuestion))”…")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text("esc to cancel · usually ~10s")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .opacity(loadingPulse && !reduceMotion ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: loadingPulse)
        .onAppear { loadingPulse = true }
        .onDisappear { loadingPulse = false }
    }

    private func preview(of s: String) -> String {
        let q = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count > 42 ? String(q.prefix(42)) + "…" : q
    }

    // MARK: - Answer (the panel fits itself to this via hosting
    // fittingSize; maxHeight caps long answers into a scroll)

    private var answerView: some View {
        ScrollView {
            MarkdownAnswer(source: answer)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
        }
        .frame(maxHeight: 440)
        .transition(.opacity)
    }

    // MARK: - Error (always with a next step — never a dead end)

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't explain that")
                        .font(.system(size: 13, weight: .semibold))
                    Text(errorText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { submit() } label: {
                    Text("Retry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canRetry)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(errorText, forType: .string)
                } label: {
                    Text("Copy error")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Text("If this mentions auth or models, run `opencode auth login` in Terminal, then Retry.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if app.hotkeyNote != nil {
                Button { showShortcut = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text("Shortcut unavailable — tap for details.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if models.needsSelection {
                Button { showModels = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text("Using \(modelTitle) — pre-selected free")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("Change")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change model, currently \(modelTitle)")
            }
            suggestionsView
        }
    }

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<Self.examples.count, id: \.self) { i in
                let ex = Self.examples[i]
                Button {
                    question = ex
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(ex)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        keycap("⏎")
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    (hoveredRow == i ? Color.primary.opacity(0.06) : .clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .padding(.horizontal, 10)
                .onHover { hoveredRow = $0 ? i : nil }
                .accessibilityLabel("Explain \(ex)")
            }
            Button { showShortcut = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Summon with")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    keycap("⇧")
                    keycap("⌃")
                    keycap("Space")
                    Text("from anywhere")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Shortcut card

    private var shortcutCard: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 20)
                .accessibilityHidden(true)
            Text("Summon Solas from anywhere")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                keycap("⇧")
                keycap("⌃")
                keycap("Space")
            }
            Text("Spotlight's ⌘Space is untouched.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            // Live status — proof across restarts, not a claim.
            VStack(spacing: 2) {
                Text("build \(BuildInfo.tag) · last received: \(app.lastFireDescription)")
                Text("capture: \(app.axTrusted ? "trusted" : "not granted") · tap: \(app.tapStatus())")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            if app.secureInputOn() {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11))
                    Text("Secure Input is ON — no hotkey can fire. Dismiss the password prompt / terminal holding keys, then retry.")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            } else if !app.axTrusted {
                Text("For summoning inside editors that swallow keys, enable keyboard capture.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            } else if app.tapStatus() != "active" {
                Text("Capture granted but the pre-dispatch tap is INACTIVE — grant Input Monitoring in System Settings, then relaunch.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            HStack(spacing: 8) {
                if !app.axTrusted {
                    Button { app.requestAXPermission() } label: {
                        Text("Enable Keyboard Capture")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button { app.copyDiagnostics() } label: {
                    Text("Copy diagnostics")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Button("Done") { showShortcut = false; inputFocused = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    // MARK: - Model picker (first run preselects free; never blocks asking)

    private func modelPicker(firstRun: Bool) -> some View {
        let ids: [String] = models.models
        let current: String? = models.selected
        return VStack(alignment: .leading, spacing: 2) {
            Text(firstRun ? "Choose your model" : "Model")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 22)
                .padding(.top, 16)
            Text(firstRun
                 ? "Pre-selected free — just type above and press ⏎. Change anytime."
                 : "Explanations use this model until you change it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.bottom, 6)

            if models.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding your opencode models…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            } else if ids.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No models found. Run `opencode auth login` in Terminal, then check again.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 22)
                    Button { Task { await models.refresh() } } label: {
                        Text("Check again")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 22)
                }
                .padding(.vertical, 12)
            } else {
                ForEach(0..<ids.count, id: \.self) { i in
                    let id = ids[i]
                    Button { pickModel(id) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ModelStore.displayName(for: id))
                                    .font(.system(size: 13, weight: .medium))
                                Text(id)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            if id == ModelStore.freeDefault {
                                Text("Free")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.green.opacity(0.14), in: Capsule())
                            }
                            if id == current {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        (hoveredModel == id ? Color.primary.opacity(0.06) : .clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .padding(.horizontal, 10)
                    .onHover { hoveredModel = $0 ? id : nil }
                }
                Button { pickModel(nil) } label: {
                    HStack {
                        Text("Follow opencode default")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if current == nil && !firstRun {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if firstRun {
                HStack {
                    Text("Free = your Zen/contributor models. No second API key.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Button("Quit Solas") { onQuit() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }
        }
    }

    private func pickModel(_ id: String?) {
        models.choose(id)
        models.markPickerIntroduced()
        showModels = false
        inputFocused = true
    }

    // MARK: - Footer

    private var modelTitle: String {
        guard let id = models.selected else { return "opencode default" }
        let name = ModelStore.displayName(for: id)
        return ModelStore.isFreeTier(id) ? "\(name) · free" : name
    }

    private func footer() -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.15)) { showModels.toggle(); showShortcut = false } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text(modelTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Image(systemName: showModels ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change model, currently \(modelTitle)")
                .disabled(isLoading)

                Spacer(minLength: 0)

                if copied && !answer.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copied")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                } else if app.hotkeyNote != nil {
                    Button { if !isLoading { showShortcut = true } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 11))
                            Text("Shortcut unavailable")
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                } else {
                    HStack(spacing: 8) {
                        keycap("⏎")
                        Text("explain")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        keycap("esc")
                        Text((!answer.isEmpty || !errorText.isEmpty) ? "clear" : "close")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Solas (submit parks to pill; smart-expand or ready badge on done)

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isLoading else { return }
        showModels = false
        showShortcut = false
        models.markPickerIntroduced() // the picker had its chance; aha moment first
        isLoading = true
        loadingQuestion = q
        errorText = ""
        answer = ""
        copied = false
        app.setThinking(true)
        app.setHasUnclearedResult(false)
        SolasLog.log("solas start model=\(models.selected ?? "default") q=\(q.prefix(60))")
        // Morph center → top-right pill; resign key so typing continues
        // elsewhere. Same panel, same entity — resized + moved.
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.82)) {
            inputFocused = false
        }
        app.parkForQuestion(q)
        Task {
            do {
                let chosen: String? = models.selected
                let result = try await onSolas(q, chosen)
                await MainActor.run {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78)) { answer = result }
                    isLoading = false
                    // A finished result owns the card: drop any picker/help
                    // opened mid-run so the answer can't be hijacked.
                    showModels = false
                    showShortcut = false
                    app.setThinking(false)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AnswerParser.plainText(from: result), forType: .string)
                    withAnimation(.easeOut(duration: 0.18)) { copied = true }
                    inputFocused = false
                    app.setHasUnclearedResult(true)
                    if app.isParked {
                        let decision = app.shouldAutoExpandNow()
                        if decision.expand {
                            app.unparkToCenter(source: "auto-expand")
                        } else {
                            app.markParkedReady(hasError: false)
                        }
                    } else if !app.isPanelVisible {
                        // Finished while hidden with no pill: reveal without
                        // reset so the result is seen, not orphaned.
                        app.showPanel(reset: false)
                    }
                    SolasLog.log("solas ok chars=\(result.count)")
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run { withAnimation { copied = false } }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isLoading = false
                    app.setThinking(false)
                    app.setHasUnclearedResult(false)
                    // Question intact — cancelled runs keep the query.
                    // If we cancelled from the pill's × we already hid;
                    // otherwise unpark so the input is visible again.
                    if app.isParked, app.isPanelVisible {
                        app.unparkToCenter(source: "unpark-cancel")
                    }
                    inputFocused = true
                    SolasLog.log("solas cancelled")
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    isLoading = false
                    showModels = false
                    showShortcut = false
                    app.setThinking(false)
                    app.setHasUnclearedResult(true)
                    if app.isParked {
                        let decision = app.shouldAutoExpandNow()
                        if decision.expand {
                            app.unparkToCenter(source: "auto-expand-error")
                            inputFocused = true
                        } else {
                            // Error parks as ⚠ — click to view Retry/Copy.
                            app.markParkedReady(hasError: true)
                        }
                    } else {
                        inputFocused = true
                        if !app.isPanelVisible { app.showPanel(reset: false) }
                    }
                    SolasLog.log("solas error: \(error.localizedDescription.prefix(200))")
                }
            }
        }
    }

    private static let examples = [
        "gravity",
        "black holes",
        "opportunity cost",
    ]
}
