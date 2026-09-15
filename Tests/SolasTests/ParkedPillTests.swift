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

    func testIconNamesAreSystemSymbolsNeverEmoji() {        for s in [PillStatus.thinking, .ready, .failed] {
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

    // MARK: - PanelFlight (spring morph math)

    private func runFlight(_ f: inout PanelFlight, maxTicks: Int = 240) -> Int {
        var ticks = 0
        while !f.isSettled, ticks < maxTicks {
            f.step(dt: 1.0 / 60.0)
            ticks += 1
        }
        return ticks
    }

    func testFlightConvergesToTarget() {
        var f = PanelFlight(
            rect: CGRect(x: 700, y: 600, width: 540, height: 300),
            target: CGRect(x: 1600, y: 1000, width: 120, height: 40),
            vel: (0, 0, 0, 0), response: 0.34, dampingRatio: 1.0
        )
        let ticks = runFlight(&f)
        XCTAssertTrue(f.isSettled)
        XCTAssertLessThan(ticks, 72, "should land in about half a second, not drag for seconds")
        XCTAssertEqual(f.rect.minX, f.target.minX, accuracy: 1.0)
        XCTAssertEqual(f.rect.width, f.target.width, accuracy: 1.0)
    }

    func testFlightSmoothNeverOvershoots() {
        var f = PanelFlight(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            target: CGRect(x: 500, y: 500, width: 200, height: 200),
            vel: (0, 0, 0, 0), response: 0.38, dampingRatio: 1.0
        )
        var maxX: CGFloat = 0
        var ticks = 0
        while !f.isSettled, ticks < 240 {
            f.step(dt: 1.0 / 60.0)
            maxX = max(maxX, f.rect.minX)
            ticks += 1
        }
        XCTAssertLessThanOrEqual(maxX, 500.5, "smooth landing must not overshoot chrome")
    }

    func testFlightRetargetPreservesContinuity() {
        var f = PanelFlight(
            rect: CGRect(x: 700, y: 600, width: 540, height: 300),
            target: CGRect(x: 1600, y: 1000, width: 120, height: 40),
            vel: (0, 0, 0, 0), response: 0.38, dampingRatio: 1.0
        )
        for _ in 0..<10 { f.step(dt: 1.0 / 60.0) } // mid-flight…
        let atInterrupt = f.rect
        let velAtInterrupt = f.vel
        // …peek redirects: same position, same velocity, new destination.
        f.retarget(
            from: atInterrupt,
            to: CGRect(x: 700, y: 600, width: 540, height: 300),
            response: 0.34, dampingRatio: 0.9
        )
        XCTAssertEqual(f.rect.minX, atInterrupt.minX)
        XCTAssertEqual(f.vel.dx, velAtInterrupt.dx)
        XCTAssertEqual(f.vel.dy, velAtInterrupt.dy)
        let ticks = runFlight(&f)
        XCTAssertTrue(f.isSettled)
        XCTAssertLessThan(ticks, 120)
    }
}
