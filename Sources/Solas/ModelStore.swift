import Foundation

/// Discovers the user's opencode models, persists the choice, and owns the
/// first-run rule: default to Muse Spark 1.3 contributor-free when the user
/// is Zen-only / has no paid subscription (i.e. the free model is present).
@MainActor
final class ModelStore: ObservableObject {
    nonisolated static let freeDefault = "opencode/muse-spark-1.3-contributor-free"
    private static let pickKey = "Solas.didPickModel"
    private static let modelKey = "Solas.selectedModel"
    private static let introKey = "Solas.didIntroducePicker"

    @Published var models: [String] = []
    @Published var selected: String?
    @Published var loading = true

    var didPick: Bool { UserDefaults.standard.bool(forKey: Self.pickKey) }
    var needsSelection: Bool { !didPick }
    /// Full picker forces itself only until the user has picked once or
    /// asked once — after that it collapses to a slim banner on idle.
    /// Never blocks asking.
    var shouldForcePicker: Bool { !didPick && !UserDefaults.standard.bool(forKey: Self.introKey) }

    /// The picker had its chance (user picked or asked). Don't force again.
    func markPickerIntroduced() {
        UserDefaults.standard.set(true, forKey: Self.introKey)
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.modelKey), !saved.isEmpty {
            selected = saved
        }
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        let all = await Task.detached(priority: .utility) {
            ModelStore.runModelsList()
        }.value
        let curated = Self.curate(all)
        self.models = curated
        if needsSelection {
            if curated.contains(Self.freeDefault) {
                selected = Self.freeDefault
            } else if selected == nil {
                selected = curated.first
            }
        }
    }

    /// `nil` = follow whatever opencode itself defaults to.
    func choose(_ id: String?) {
        selected = id
        if let id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: Self.modelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.modelKey)
        }
        UserDefaults.standard.set(true, forKey: Self.pickKey)
    }

    // MARK: - Curation + display

    /// Keep the picker short: the free default first, then other
    /// free / spark / zen / contributor builds, capped at 12.
    nonisolated static func curate(_ all: [String]) -> [String] {
        var out: [String] = []
        if all.contains(freeDefault) { out.append(freeDefault) }
        for id in all {
            guard out.count < 12, id != freeDefault, !out.contains(id) else { continue }
            let l = id.lowercased()
            if l.contains("spark") || l.contains("free") || l.contains("zen") || l.contains("contributor") {
                out.append(id)
            }
        }
        return out
    }

    /// "opencode/muse-spark-1.3-contributor-free" -> ("Muse Spark 1.3", "Free").
    nonisolated static func displayName(for id: String) -> String {
        var short = id.split(separator: "/").last.map(String.init) ?? id
        for suffix in ["-contributor-free", "-contributor", "-free"] where short.hasSuffix(suffix) {
            short = String(short.dropLast(suffix.count))
            break
        }
        return short.split(separator: "-").map { part -> String in
            guard let first = part.first else { return String(part) }
            if part.contains(".") || part.first?.isNumber == true { return String(part) }
            return String(first).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    nonisolated static func isFreeTier(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.contains("free") || l.contains("contributor") || l.contains("zen")
    }

    // MARK: - Plumbing (off the main actor)

    nonisolated static func runModelsList() -> [String] {
        let proc = Process()
        proc.executableURL = OpencodeRunner.locateBinary()
        proc.arguments = ["models"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        guard proc.terminationStatus == 0 else { return [] }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { $0.split(separator: " ").first.map(String.init) }
            .filter { $0.contains("/") }
    }
}
