import XCTest
@testable import Solas

final class MarkdownBlocksTests: XCTestCase {
    func testParagraphAndHeading() {
        let blocks = AnswerParser.blocks(from: "# Big\n\nHello **world**")
        XCTAssertEqual(blocks.count, 2)
        if case .heading(let level) = blocks[0].kind {
            XCTAssertEqual(level, 1)
        } else {
            XCTFail("expected heading")
        }
        if case .paragraph = blocks[1].kind {} else {
            XCTFail("expected paragraph")
        }
    }

    func testBulletsAndNumbered() {
        let blocks = AnswerParser.blocks(from: "- **Mass** attracts\n1. First step")
        XCTAssertEqual(blocks.count, 2)
        if case .bullet = blocks[0].kind {} else { XCTFail("expected bullet") }
        if case .numbered(_, let n) = blocks[1].kind {
            XCTAssertEqual(n, 1)
        } else { XCTFail("expected numbered") }
    }

    func testQuoteAndCodeFence() {
        let src = "> an analogy here\n\n```swift\nlet x = 1\n```"
        let blocks = AnswerParser.blocks(from: src)
        XCTAssertEqual(blocks.count, 2)
        if case .quote = blocks[0].kind {} else { XCTFail("expected quote") }
        if case .code(let lang) = blocks[1].kind {
            XCTAssertEqual(lang, "swift")
            XCTAssertTrue(blocks[1].inlineSource.contains("let x"))
        } else { XCTFail("expected code") }
    }

    func testUnclosedCodeRunsToEnd() {
        let blocks = AnswerParser.blocks(from: "```\nhello")
        XCTAssertEqual(blocks.count, 1)
        if case .code = blocks[0].kind {} else { XCTFail("expected code") }
    }

    func testBareFenceOnlyCloses() {
        // ```lang inside a block is literal content, not a closer.
        let src = "```\n```swift still code\n```"
        let blocks = AnswerParser.blocks(from: src)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].inlineSource.contains("```swift still code"))
    }

    func testImageAllowlist() {
        let ok = URL(string: "https://upload.wikimedia.org/wikipedia/a.jpg")!
        let bad = URL(string: "https://example.com/a.jpg")!
        XCTAssertTrue(AnswerParser.isAllowedImageHost(ok))
        XCTAssertFalse(AnswerParser.isAllowedImageHost(bad))
        XCTAssertNil(AnswerParser.parseImageLine("not an image"))
        XCTAssertNotNil(AnswerParser.parseImageLine("![cat](https://upload.wikimedia.org/wikipedia/a.jpg)"))
    }

    func testAccentNamesConstrainedToPalette() {
        let src = "word ^[mass](accent: 'sky') and ^[nope](accent: 'banana')"
        XCTAssertEqual(AnswerParser.accentNames(in: src), ["sky"])
    }

    func testPlainTextStripsMarkup() {
        let src = "**Gravity** is ^[mass](accent: 'sky') attracting [Earth](https://example.com)"
        let plain = AnswerParser.plainText(from: src)
        XCTAssertEqual(plain, "Gravity is mass attracting Earth")
    }
}
