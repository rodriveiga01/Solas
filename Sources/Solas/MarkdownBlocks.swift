import Foundation

/// One renderable chunk of an explainer answer.
struct AnswerBlock: Sendable {
    enum Kind: Sendable {
        case heading(level: Int)
        case paragraph
        case bullet(depth: Int)
        case numbered(depth: Int, number: Int)
        case quote
        case code(language: String?)
        case image(alt: String, url: URL)
    }
    /// Markdown *inline* source (bold/italic/code/links/accents). For `.code`
    /// this is the raw literal text instead.
    let inlineSource: String
    let kind: Kind
}

/// Main-thread render cache. Block splitting is cheap, but Foundation
/// Markdown parsing (`AttributedString(markdown:)`) plus per-call compiled
/// regexes, run per block on every body evaluation, cost real frame time —
/// reopening the card rebuilt everything live and read as blank-then-pop.
/// Parsing is pure, so cache it: reopen becomes a lookup, not a re-render.
final class AnswerRenderCache: @unchecked Sendable {
    static let shared = AnswerRenderCache()
    private let lock = NSLock()
    private var blocksBySource: [String: [AnswerBlock]] = [:]
    private var styledByKey: [String: AttributedString] = [:]

    func blocks(for source: String, compute: () -> [AnswerBlock]) -> [AnswerBlock] {
        lock.lock()
        let hit = blocksBySource[source]
        lock.unlock()
        if let hit { return hit }
        let v = compute()
        lock.lock()
        if blocksBySource.count > 8 { blocksBySource.removeAll() }
        blocksBySource[source] = v
        lock.unlock()
        return v
    }

    func styled(key: String, compute: () -> AttributedString) -> AttributedString {
        lock.lock()
        let hit = styledByKey[key]
        lock.unlock()
        if let hit { return hit }
        let v = compute()
        lock.lock()
        if styledByKey.count > 300 { styledByKey.removeAll() }
        styledByKey[key] = v
        lock.unlock()
        return v
    }
}
/// Custom inline attribute the model can emit as `^[term](accent: 'ember')`,
/// decoded straight out of the Markdown by Foundation. Constrained to
/// `AccentPalette.names` at render time — unknown names are ignored.
enum AccentAttribute: DecodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    typealias Value = String
    static let name = "accent"
}

extension AttributeScopes {
    struct SolasCustom: AttributeScope {
        let accent: AccentAttribute
    }
    var solas: SolasCustom.Type { SolasCustom.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SolasCustom, T>) -> T {
        self[T.self]
    }
}

enum AnswerParser {
    // MARK: - Block splitting (line-based, zero dependencies)

    /// Compiled once: `range(of:options:.regularExpression)` recompiles the
    /// pattern on every call — per line, per body evaluation. These are
    /// fixed literals, so `try!` cannot fail.
    private static let fenceCloseRe = try! NSRegularExpression(pattern: #"^```\s*$"#)
    private static let numberedRe = try! NSRegularExpression(pattern: #"^(\d+)[.)] "#)
    private static let imageLineRe = try! NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^)\s]+)\)\s*$"#)
    private static let accentRe = try! NSRegularExpression(pattern: #"\^\[[^\]]+\]\(accent:\s*'([A-Za-z]+)'\)"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
    }

    /// Cached: pure function of `source`, called from body on every eval.
    static func blocks(from source: String) -> [AnswerBlock] {
        AnswerRenderCache.shared.blocks(for: source) { parseBlocks(from: source) }
    }

    private static func parseBlocks(from source: String) -> [AnswerBlock] {
        var out: [AnswerBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]? = nil
        var codeLanguage: String? = nil

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(AnswerBlock(inlineSource: text, kind: .paragraph)) }
            paragraph = []
        }
        func flushQuote() {
            let text = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(AnswerBlock(inlineSource: text, kind: .quote)) }
            quote = []
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .init(charactersIn: " \t"))

            if let _ = code {
                // Only a bare fence closes (CommonMark: closing fences carry
                // no info string). A ```lang line inside is literal content.
                if !matches(fenceCloseRe, line).isEmpty {
                    out.append(AnswerBlock(inlineSource: code!.joined(separator: "\n"), kind: .code(language: codeLanguage)))
                    code = nil
                    codeLanguage = nil
                } else {
                    code!.append(rawLine)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph(); flushQuote()
                code = []
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? nil : lang
                continue
            }
            if line.isEmpty {
                flushParagraph(); flushQuote()
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .init(charactersIn: " ")))
                continue
            }
            flushQuote()
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flushParagraph()
                    let text = String(line.dropFirst(level + 1))
                    out.append(AnswerBlock(inlineSource: text, kind: .heading(level: min(level, 3))))
                    continue
                }
            }
            if line.hasPrefix("!["),
               let img = Self.parseImageLine(line) {
                flushParagraph()
                out.append(AnswerBlock(inlineSource: line, kind: .image(alt: img.alt, url: img.url)))
                continue
            }
            if let item = parseListItem(line) {
                flushParagraph()
                out.append(item)
                continue
            }
            paragraph.append(line)
        }
        flushParagraph(); flushQuote()
        if let unfinished = code {
            out.append(AnswerBlock(inlineSource: unfinished.joined(separator: "\n"), kind: .code(language: codeLanguage)))
        }
        return out
    }

    private static func parseListItem(_ line: String) -> AnswerBlock? {
        var idx = line.startIndex
        var spaces = 0
        while idx < line.endIndex, line[idx] == " " { spaces += 1; idx = line.index(after: idx) }
        while idx < line.endIndex, line[idx] == "\t" { spaces += 2; idx = line.index(after: idx) }
        let rest = String(line[idx...])
        let depth = min(spaces / 2, 4)
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            return AnswerBlock(inlineSource: String(rest.dropFirst(2)), kind: .bullet(depth: depth))
        }
        if let m = matches(numberedRe, rest).first, m.numberOfRanges >= 2 {
            let ns = rest as NSString
            let num = Int(ns.substring(with: m.range(at: 1))) ?? 1
            return AnswerBlock(inlineSource: String(ns.substring(from: m.range.upperBound)), kind: .numbered(depth: depth, number: num))
        }
        return nil
    }

    // MARK: - Images (copyright-safe by construction)

    /// Only standalone `![alt](https://…)` lines become images. Anything else
    /// with `!` falls through to normal paragraph parsing.
    static func parseImageLine(_ line: String) -> (alt: String, url: URL)? {
        let ns = line as NSString
        guard let m = matches(imageLineRe, line).first, m.numberOfRanges == 3 else { return nil }
        let alt = ns.substring(with: m.range(at: 1))
        let urlString = ns.substring(with: m.range(at: 2))
        guard let url = URL(string: urlString), url.scheme == "https" else { return nil }
        return (alt, url)
    }

    /// Freely-licensed hosts only: Wikimedia Commons serves originals from
    /// upload.wikimedia.org and thumbnails from thumb.wikimedia.org.
    /// Anything else renders as a link row — never a hotlinked image.
    static let allowedImageHosts = ["upload.wikimedia.org", "thumb.wikimedia.org", "commons.wikimedia.org"]

    static func isAllowedImageHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return allowedImageHosts.contains(host)
    }

    // MARK: - Inline parsing (Foundation Markdown, custom accent included)

    static func parseInline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, including: \.solas))
            ?? AttributedString(s)
    }

    /// Accent names in order of first appearance, constrained to the palette.
    static func accentNames(in source: String) -> [String] {
        let ns = source as NSString
        var seen: [String] = []
        for m in matches(accentRe, source) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if AccentPalette.names.contains(name), !seen.contains(name) {
                seen.append(name)
            }
        }
        return seen
    }

    // MARK: - Plain text (for clipboard: markup stripped, words kept)

    static func plainText(from source: String) -> String {
        var s = source
        s = s.replacingOccurrences(of: "```[A-Za-z0-9+-]*\\n?", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.replacingOccurrences(of: #"!\[([^\]]+)\]\([^)]+\)"#, with: "[Image: $1]", options: .regularExpression)
        s = s.replacingOccurrences(of: #"!\[\]\([^)]+\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\^\[([^\]]+)\]\(accent:\s*'[A-Za-z]+'\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)
        for marker in ["**", "~~"] { s = s.replacingOccurrences(of: marker, with: "") }
        s = s.replacingOccurrences(of: "(?<!\\w)\\*(?!\\s)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "`", with: "")
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Fixed accent palette. Names are the model's whole vocabulary for color;
/// anything else falls back to uncolored text. System colors auto-adapt to
/// light/dark; gold gets a custom adaptive pair (pure yellow is unreadable
/// on light backgrounds).
enum AccentPalette {
    static let names = ["ember", "gold", "leaf", "sky", "iris", "rose"]
}
