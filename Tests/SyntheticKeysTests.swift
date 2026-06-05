import CoreGraphics
import XCTest
@testable import Relay

/// The self-event sentinel round-trip: a CGEvent stamped with Relay's sentinel is
/// recognized by `isRelaySynthetic`, a plain event is not. No events are posted —
/// this exercises only the stamp/detect helpers. `nonisolated` per the MainActor rule.
nonisolated final class SyntheticKeysTests: XCTestCase {

    func testStampedEventIsRecognized() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticKeys.sentinel)
        XCTAssertTrue(SyntheticKeys.isRelaySynthetic(event))
    }

    func testUnstampedEventIsNotRecognized() throws {
        // A fresh event defaults `eventSourceUserData` to 0, which is not the sentinel.
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        XCTAssertFalse(SyntheticKeys.isRelaySynthetic(event))
    }
}
