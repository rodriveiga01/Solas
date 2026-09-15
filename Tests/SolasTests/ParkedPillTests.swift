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
}
