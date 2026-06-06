import XCTest
import AppKit
@testable import Relay

/// HotkeyMatcher press/release decoding, including self-correction after a missed
/// flagsChanged event (which used to invert the toggle permanently).
nonisolated final class HotkeyMatcherTests: XCTestCase {
    private let rightCmd = Keybind.rightCommand   // keyCode 54, bare .command

    func testNormalPressThenRelease() {
        var m = HotkeyMatcher(keybind: rightCmd)
        XCTAssertEqual(m.handleFlagsChanged(keyCode: 54, flags: [.command]), .press)
        XCTAssertEqual(m.handleFlagsChanged(keyCode: 54, flags: []), .release)
    }

    func testMissedPressDoesNotEmitSpuriousPressOnRelease() {
        // The press event was dropped (monitor armed mid-hold). The release (flag
        // absent) must resolve to "up" with no transition — NOT toggle up into a
        // bogus press as the old self-toggling boolean did.
        var m = HotkeyMatcher(keybind: rightCmd)
        XCTAssertNil(m.handleFlagsChanged(keyCode: 54, flags: []))
        // And the next clean press/release works.
        XCTAssertEqual(m.handleFlagsChanged(keyCode: 54, flags: [.command]), .press)
        XCTAssertEqual(m.handleFlagsChanged(keyCode: 54, flags: []), .release)
    }

    func testReleaseResyncsAfterDesync() {
        // Force a desync: deliver two presses in a row (a missed release between).
        var m = HotkeyMatcher(keybind: rightCmd)
        _ = m.handleFlagsChanged(keyCode: 54, flags: [.command])   // press
        // A spurious second flag-present event toggles us back to "up" (the ambiguous
        // path), but the eventual real release (flag absent) snaps us to a consistent
        // up state and a subsequent press is clean.
        _ = m.handleFlagsChanged(keyCode: 54, flags: [.command])
        _ = m.handleFlagsChanged(keyCode: 54, flags: [])           // definitive up
        XCTAssertEqual(m.handleFlagsChanged(keyCode: 54, flags: [.command]), .press)
    }

    func testOtherKeyCodeIgnored() {
        var m = HotkeyMatcher(keybind: rightCmd)
        XCTAssertNil(m.handleFlagsChanged(keyCode: 55, flags: [.command]))
    }
}
