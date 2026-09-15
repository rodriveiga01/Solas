import XCTest
@testable import Solas

final class SanitizeTests: XCTestCase {
    func testStripsSessionHeaderButKeepsQuotes() {
        let raw = "> solas-abc123 · thinking\n**Gravity** is mass attracting mass."
        let out = OpencodeRunner.sanitize(raw)
        XCTAssertFalse(out.contains("solas-abc123"))
        XCTAssertTrue(out.contains("Gravity"))
    }

    func testKeepsRealBlockquote() {
        let raw = "> to be, or not to be"
        XCTAssertTrue(OpencodeRunner.sanitize(raw).contains("to be"))
    }

    func testStripsANSIEscapeCodes() {
        let raw = "\u{1B}[32m**Bold**\u{1B}[0m plain"
        let out = OpencodeRunner.sanitize(raw)
        XCTAssertTrue(out.contains("**Bold**"))
        XCTAssertFalse(out.contains("\u{1B}"))
    }

    func testStripsStatusAndSpinnerPrefixes() {
        let raw = "⠋ Searching the web\n● Reading files\nReal content here"
        let out = OpencodeRunner.sanitize(raw)
        XCTAssertFalse(out.contains("Searching"))
        XCTAssertTrue(out.contains("Real content"))
    }

    func testCollapsesTripleNewlinesAndTrims() {
        let raw = "  line one\n\n\nline two  \n"
        XCTAssertEqual(OpencodeRunner.sanitize(raw), "line one\n\nline two")
    }

    func testExplainerPromptEmbedsQuestion() {
        let prompt = OpencodeRunner.explainerPrompt(for: "gravity")
        XCTAssertTrue(prompt.contains("gravity"))
        XCTAssertTrue(prompt.contains("120 words"))
    }

    func testExplainerPromptAnswersInUserLanguage() {
        let prompt = OpencodeRunner.explainerPrompt(for: "gravedad")
        XCTAssertTrue(prompt.contains("gravedad"))
        XCTAssertTrue(prompt.lowercased().contains("same language"))
        XCTAssertTrue(prompt.lowercased().contains("default to english"))
    }
}
