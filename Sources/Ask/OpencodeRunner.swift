import Foundation

/// User-facing failures. Every case names the problem and the recovery —
/// the card never goes blank after a run.
enum AskRunError: LocalizedError {
    case emptyQuestion
    case binaryMissing(path: String)
    case launchFailed(String)
    case timeout(seconds: Int)
    case authNeeded(String)
    case modelMissing(String)
    case emptyOutput(exit: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .emptyQuestion: return "Type a concept first."
        case .binaryMissing(let p): return "opencode not found at \(p). Install opencode and run `opencode auth login` in Terminal."
        case .launchFailed(let m): return m.isEmpty ? "Couldn't start opencode." : m
        case .timeout(let s): return "opencode took longer than \(s)s and was stopped. Try a shorter question or another model."
        case .authNeeded(let m): return m.isEmpty ? "opencode needs login. Run `opencode auth login` in Terminal, then retry." : m
        case .modelMissing(let m): return m.isEmpty ? "That model isn't available. Pick another model below." : m
        case .emptyOutput(let exit, let err):
            if !err.isEmpty { return err }
            return "opencode returned nothing (exit \(exit)). Try again or pick another model."
        }
    }
}

/// Thin wrapper around the user's existing `opencode` binary.
/// Uses `opencode run` headless so we inherit auth, providers, models.
final class OpencodeRunner: Sendable {
    private let binary: URL
    private let runState = RunState()

    private final class RunState: @unchecked Sendable {
        let lock = NSLock()
        var process: Process?
        var cancelled = false
        var timedOut = false
    }

    init(binary: URL? = nil) {
        self.binary = binary ?? Self.locateBinary()
    }

    var binaryPath: String { binary.path }

    static func locateBinary() -> URL {
        let fm = FileManager.default
        let candidates = [
            "\(NSHomeDirectory())/.opencode/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let out = try? shellOut("/usr/bin/which", ["opencode"]),
           let first = out.split(separator: "\n").first,
           fm.isExecutableFile(atPath: String(first)) {
            return URL(fileURLWithPath: String(first))
        }
        return URL(fileURLWithPath: candidates[0])
    }

    func cancelCurrent() {
        runState.lock.lock()
        runState.cancelled = true
        let proc = runState.process
        runState.lock.unlock()
        proc?.terminate()
    }

    /// Explain a concept. Always returns Markdown or throws AskRunError —
    /// never an empty success (the card always has something to show).
    func ask(_ question: String, model: String?, timeoutSeconds: Int = 120) async throws -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw AskRunError.emptyQuestion }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw AskRunError.binaryMissing(path: binary.path)
        }
        let prompt = Self.explainerPrompt(for: q)
        let binary = self.binary
        let modelArg = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = Date()

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = binary
                var args = ["run"]
                if let m = modelArg, !m.isEmpty { args += ["-m", m] }
                args.append(prompt)
                proc.arguments = args
                proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                var env = ProcessInfo.processInfo.environment
                env["TERM"] = "dumb"
                env["NO_COLOR"] = "1"
                env["CLICOLOR"] = "0"
                proc.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                self.runState.lock.lock()
                self.runState.process = proc
                self.runState.cancelled = false
                self.runState.timedOut = false
                self.runState.lock.unlock()

                do { try proc.run() } catch {
                    self.clearRun(process: nil)
                    cont.resume(throwing: AskRunError.launchFailed(error.localizedDescription))
                    return
                }

                // Drain concurrently, started only after a successful launch:
                // opencode's TUI chrome can exceed the 64KB pipe buffer,
                // which would deadlock waitUntilExit. (Starting drains
                // before run() risks wedged readers on launch failure.)
                // Locked boxes: the writes happen-before group.wait().
                final class DrainBox: @unchecked Sendable {
                    let lock = NSLock()
                    var data = Data()
                }
                let outBox = DrainBox()
                let errBox = DrainBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let d = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    outBox.lock.lock(); outBox.data = d; outBox.lock.unlock()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let d = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    errBox.lock.lock(); errBox.data = d; errBox.lock.unlock()
                    group.leave()
                }

                // Watchdog: never hang the card forever.
                let watchdog = DispatchWorkItem {
                    self.runState.lock.lock()
                    let p = self.runState.process
                    self.runState.lock.unlock()
                    if let p, p.isRunning {
                        self.runState.lock.lock()
                        self.runState.timedOut = true
                        self.runState.lock.unlock()
                        p.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if p.isRunning { p.interrupt() }
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: watchdog)

                proc.waitUntilExit()
                watchdog.cancel()
                group.wait()

                self.runState.lock.lock()
                let wasCancelled = self.runState.cancelled
                let didTimeout = self.runState.timedOut
                if self.runState.process === proc { self.runState.process = nil }
                self.runState.lock.unlock()

                if wasCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                if didTimeout {
                    cont.resume(throwing: AskRunError.timeout(seconds: timeoutSeconds))
                    return
                }

                let raw = String(data: outBox.data, encoding: .utf8) ?? ""
                let err = String(data: errBox.data, encoding: .utf8) ?? ""
                let clean = Self.sanitize(raw)
                let secs = String(format: "%.1f", Date().timeIntervalSince(started))
                AskLog.log("ask done model=\(modelArg ?? "default") exit=\(proc.terminationStatus) secs=\(secs) cleanChars=\(clean.count)")

                if proc.terminationStatus == 0, !clean.isEmpty {
                    cont.resume(returning: clean)
                    return
                }
                let errTrim = Self.sanitize(err).trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = (clean + "\n" + errTrim).lowercased()
                if lower.contains("auth") || lower.contains("login") || lower.contains("401") || lower.contains("unauthorized") {
                    cont.resume(throwing: AskRunError.authNeeded(errTrim.isEmpty ? clean : errTrim))
                } else if lower.contains("model") && (lower.contains("not found") || lower.contains("unknown") || lower.contains("invalid")) {
                    cont.resume(throwing: AskRunError.modelMissing(errTrim.isEmpty ? clean : errTrim))
                } else {
                    let msg = clean.isEmpty ? errTrim : clean
                    cont.resume(throwing: AskRunError.emptyOutput(exit: proc.terminationStatus, stderr: msg))
                }
            }
        }
    }

    private func clearRun(process: Process?) {
        runState.lock.lock()
        if process == nil || runState.process === process { runState.process = nil }
        runState.lock.unlock()
    }

    // MARK: - The explainer brief

    static func explainerPrompt(for q: String) -> String {
        let safe = q.replacingOccurrences(of: "\"", with: "'")
        return """
        You power Ask, a tiny macOS popup that explains concepts in one glance. The user typed: "\(safe)". \
        If it is a concept, explain it; if it is a question, answer it directly. Same compact style either way.
        Format the answer in Markdown, under 120 words total:
        - One striking essence line in bold first.
        - Then 2 to 4 short bullets; bold the key term in each.
        - Optionally one short italic analogy or example as the last line.
        - No headings, no preamble like "Here is", no closing line.
        You may tint at most 3 key terms with ^[term](accent: 'NAME'), where NAME is exactly one of: \
        ember, gold, leaf, sky, iris, rose. Only the most important words — restraint reads as craft.
        Images: only if a picture would genuinely clarify the concept, add at most 2, each as its own \
        line: ![what the image shows](URL). Visual subjects (animals, places, objects, artworks, diagrams, \
        people) usually deserve one image when you know a real Commons URL for them. Rules: only Wikimedia \
        Commons URLs (upload.wikimedia.org originals or thumb.wikimedia.org thumbnails) you are confident \
        really exist — real article images you know, never guessed filenames. If unsure, omit images \
        entirely. Never hotlink any other site.
        """
    }

    // MARK: - Output sanitizing

    /// `opencode run` prints TUI chrome. Strip it but preserve Markdown —
    /// including `>` blockquotes, which resemble the session header.
    static func sanitize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}\u{7F}]", with: "", options: .regularExpression)

        let statusPrefixes = ["◈", "⬢", "●", "○", "◆", "ℹ", "⚠", "✖", "✔",
                              "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "⣿"]
        let leadingChatter = ["i'll", "let me", "i will", "searching", "running", "reading", "checking", "looking"]

        var kept: [String] = []
        var seenContent = false
        for rawLine in s.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if seenContent { kept.append("") }
                continue
            }
            if line.hasPrefix(">") {
                if line.range(of: "^>\\s+[\\w.\\-]+\\s+·", options: .regularExpression) != nil { continue }
                seenContent = true
                kept.append(rawLine.trimmingCharacters(in: .init(charactersIn: " \t")))
                continue
            }
            if statusPrefixes.contains(where: { line.hasPrefix($0) }) { continue }
            let lower = line.lowercased()
            if !seenContent, leadingChatter.contains(where: { lower.hasPrefix($0) }) { continue }
            seenContent = true
            kept.append(rawLine.trimmingCharacters(in: .init(charactersIn: " \t")))
        }
        var out = kept.joined(separator: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shellOut(_ bin: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        return String(data: (try? pipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
    }
}

/// Build identity: stamped per package by scripts/package.sh
/// (CFBundleVersion). The help card shows it so a stale /Applications
/// copy can never masquerade as the new build.
enum BuildInfo {
    static var tag: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev-binary"
    }
}
/// Lives at ~/Library/Logs/Ask.log; capped at 256KB (keeps the tail).
/// Failures to write are ignored.
enum AskLog {
    private static let maxBytes = 256 * 1024

    static func log(_ msg: String) {
        let line = msg + "\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        guard let url = logURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(url)
        if let fh = try? FileHandle(forWritingTo: url) {
            _ = try? fh.seekToEnd()
            if let stamped = ("\(ISO8601DateFormatter().string(from: Date())) \(msg)\n").data(using: .utf8) {
                try? fh.write(contentsOf: stamped)
            }
            try? fh.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    /// Drop the oldest half once over budget — the recent tail is what
    /// diagnoses a failure.
    private static func rotateIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let tail = data.suffix(maxBytes / 2)
        // Start on a line boundary so the kept tail stays readable.
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) {
            try? tail[tail.index(after: nl)...].write(to: url)
        } else {
            try? tail.write(to: url)
        }
    }
    private static var logURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Ask.log")
    }
}
