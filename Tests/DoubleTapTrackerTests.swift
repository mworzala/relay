import XCTest
@testable import Relay

/// `DoubleTapTracker` second-tap detection: a quick tap followed by a press within
/// the window is a double-tap; outside the window, or without a preceding quick
/// tap, it isn't. Times are explicit monotonic seconds.
nonisolated final class DoubleTapTrackerTests: XCTestCase {
    func testLonePressIsNotSecondTap() {
        var t = DoubleTapTracker(windowSeconds: 0.35)
        XCTAssertFalse(t.registerPress(at: 1.0))
    }

    func testQuickTapThenPressWithinWindowIsDoubleTap() {
        var t = DoubleTapTracker(windowSeconds: 0.35)
        XCTAssertFalse(t.registerPress(at: 1.0))   // tap 1 down
        t.registerQuickTap()                       // tap 1 released during arming
        XCTAssertTrue(t.registerPress(at: 1.2))    // tap 2 down, 200ms later → latch
    }

    func testQuickTapThenPressOutsideWindowIsNotDoubleTap() {
        var t = DoubleTapTracker(windowSeconds: 0.35)
        _ = t.registerPress(at: 1.0)
        t.registerQuickTap()
        XCTAssertFalse(t.registerPress(at: 1.5))   // 500ms later → too slow
    }

    func testBoundaryIsInclusive() {
        // Use exactly-representable values so the edge compares cleanly (a gap equal
        // to the window counts as a double-tap: the predicate is `<=`).
        var t = DoubleTapTracker(windowSeconds: 0.5)
        _ = t.registerPress(at: 1.0)
        t.registerQuickTap()
        XCTAssertTrue(t.registerPress(at: 1.5))   // gap == window
    }

    func testPressWithoutPriorQuickTapIsNotDoubleTap() {
        // A press that started a real session (no registerQuickTap) must not arm a
        // latch for the following press.
        var t = DoubleTapTracker(windowSeconds: 0.35)
        _ = t.registerPress(at: 1.0)               // tap 1, but it became a hold (no quick tap)
        XCTAssertFalse(t.registerPress(at: 1.1))   // tap 2 close in time, but unpaired
    }

    func testPendingTapIsConsumedSoThirdPressDoesNotRelatch() {
        var t = DoubleTapTracker(windowSeconds: 0.35)
        _ = t.registerPress(at: 1.0)
        t.registerQuickTap()
        XCTAssertTrue(t.registerPress(at: 1.2))    // double-tap detected, pending consumed
        XCTAssertFalse(t.registerPress(at: 1.3))   // a third quick press isn't a fresh latch
    }

    func testResetClearsPendingTap() {
        var t = DoubleTapTracker(windowSeconds: 0.35)
        _ = t.registerPress(at: 1.0)
        t.registerQuickTap()
        t.reset()
        XCTAssertFalse(t.registerPress(at: 1.1))   // pending dropped → not a double-tap
    }
}
