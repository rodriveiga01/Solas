import XCTest
@testable import Solas

final class ParkedPillTests: XCTestCase {
    func testTruncateShortPassthrough() {
        XCTAssertEqual(ParkedPill.truncate("gravity"), "gravity")
    }

    func testTruncateLongAddsEllipsisAt42() {
        let long = String(repeating: "a", count: 60)
        let out = ParkedPill.truncate(long)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertEqual(out.count, 43)
    }

    func testTruncateTrimsWhitespace() {
        XCTAssertEqual(ParkedPill.truncate("  gravity  \n"), "gravity")
    }

    func testAutoExpandWhenStillWaiting() {
        let r = ParkedPill.shouldAutoExpand(
            frontAtSubmit: "com.apple.Safari",
            frontAtDone: "com.apple.Safari",
            secureInputOn: false,
            elapsed: 9
        )
        XCTAssertTrue(r.expand, r.reason)
    }

    func testStayParkedWhenFrontChanged() {
        let r = ParkedPill.shouldAutoExpand(
            frontAtSubmit: "com.solas",
            frontAtDone: "com.apple.Safari",
            secureInputOn: false,
            elapsed: 5
        )
        XCTAssertFalse(r.expand)
        XCTAssertTrue(r.reason.contains("front-changed"))
    }

    func testNeverExpandOnSecureInput() {
        let r = ParkedPill.shouldAutoExpand(
            frontAtSubmit: "com.solas",
            frontAtDone: "com.solas",
            secureInputOn: true,
            elapsed: 3
        )
        XCTAssertFalse(r.expand)
        XCTAssertEqual(r.reason, "secure-input-on")
    }

    func testStayParkedWhenSlow() {
        let r = ParkedPill.shouldAutoExpand(
            frontAtSubmit: "com.solas",
            frontAtDone: "com.solas",
            secureInputOn: false,
            elapsed: 45
        )
        XCTAssertFalse(r.expand)
        XCTAssertTrue(r.reason.contains("elapsed"))
    }

    func testStayParkedWhenUnsure() {
        let r = ParkedPill.shouldAutoExpand(
            frontAtSubmit: nil,
            frontAtDone: "com.solas",
            secureInputOn: false,
            elapsed: 2
        )
        XCTAssertFalse(r.expand)
        XCTAssertEqual(r.reason, "unknown-submit-front")
    }

    func testStateMachinePhases() {
        // idle → thinking-parked → ready-parked → expanded
        var phase = ParkPhase.full
        XCTAssertEqual(phase, .full)
        phase = .thinkingParked
        XCTAssertEqual(phase, .thinkingParked)
        phase = .readyParked(hasError: false)
        XCTAssertEqual(phase, .readyParked(hasError: false))
        XCTAssertNotEqual(phase, .readyParked(hasError: true))
        phase = .full
        XCTAssertEqual(phase, .full)
    }

    func testStatusMapping() {
        XCTAssertEqual(ParkedPill.status(isReady: false, hasError: false), .thinking)
        XCTAssertEqual(ParkedPill.status(isReady: true, hasError: false), .ready)
        XCTAssertEqual(ParkedPill.status(isReady: true, hasError: true), .failed)
    }

    func testIconNamesAreSystemSymbolsNeverEmoji() {
        for s in [PillStatus.thinking, .ready, .failed] {
            let name = ParkedPill.iconName(for: s)
            XCTAssertFalse(name.isEmpty)
            // SF Symbols contain dots/dashes only — no emoji scalar range.
            XCTAssertTrue(name.allSatisfy { $0.isLetter || $0 == "." || $0 == "-" || $0 == "2" })
        }
        XCTAssertNotEqual(ParkedPill.iconName(for: .ready), ParkedPill.iconName(for: .failed))
    }

    func testPillWidthHugsShortWords() {
        let narrow = ParkedPill.pillWidth(for: "hi")
        let wide = ParkedPill.pillWidth(for: "black holes")
        XCTAssertLessThan(narrow, wide)
        XCTAssertGreaterThanOrEqual(narrow, 80)
    }

    func testPillWidthClamps() {
        XCTAssertEqual(ParkedPill.pillWidth(for: ""), 80)
        XCTAssertEqual(ParkedPill.pillWidth(for: String(repeating: "w", count: 200)), 320)
    }

    func testPillWidthChargesIconBudgetOnlyWhenShown() {
        let plain = ParkedPill.pillWidth(for: "black holes", showsIcon: false)
        let withIcon = ParkedPill.pillWidth(for: "black holes", showsIcon: true)
        XCTAssertEqual(withIcon - plain, 24, accuracy: 1.0)
    }
}
