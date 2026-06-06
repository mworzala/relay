import XCTest
@testable import Relay

/// The IMK IPC wire contract (`IMKMessaging`) and the engagement-mode persistence —
/// the unit-testable pure logic of plan 08. The transport (CFMessagePort), TIS, and
/// AppKit focus-churn need a real login session + GUI and are verified interactively.
/// `nonisolated` per the MainActor-default rule.
nonisolated final class IMKMessagingTests: XCTestCase {

    // MARK: - Payload coding round-trips

    func testStringDataRoundTrip() {
        for sample in ["", "hello", "so I think we should meet", "café — 4PM ✅", "日本語"] {
            let data = IMKMessaging.data(sample)
            XCTAssertEqual(IMKMessaging.string(data), sample)
        }
    }

    func testStringFromNilDataIsEmpty() {
        XCTAssertEqual(IMKMessaging.string(nil), "")
    }

    // MARK: - Verb identifiers are stable and distinct

    func testCommandRawValuesAreStableAndUnique() {
        // The raw values are the on-the-wire msgids; both sides must agree, so pin them.
        XCTAssertEqual(IMKMessaging.Command.ping.rawValue, 1)
        XCTAssertEqual(IMKMessaging.Command.beginDictation.rawValue, 2)
        XCTAssertEqual(IMKMessaging.Command.engageJustInTime.rawValue, 3)
        XCTAssertEqual(IMKMessaging.Command.setMarked.rawValue, 4)
        XCTAssertEqual(IMKMessaging.Command.commit.rawValue, 5)
        XCTAssertEqual(IMKMessaging.Command.clear.rawValue, 6)
        XCTAssertEqual(IMKMessaging.Command.endDictation.rawValue, 7)

        let all: [IMKMessaging.Command] = [.ping, .beginDictation, .engageJustInTime,
                                           .setMarked, .commit, .clear, .endDictation]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count, "command msgids must be unique")
    }

    func testEventRawValues() {
        XCTAssertEqual(IMKMessaging.Event.engaged.rawValue, 1)
        XCTAssertEqual(IMKMessaging.Event.disengaged.rawValue, 2)
    }

    func testUnknownMsgidDoesNotMapToACommand() {
        XCTAssertNil(IMKMessaging.Command(rawValue: 0))
        XCTAssertNil(IMKMessaging.Command(rawValue: 99))
    }

    // MARK: - Identity invariants (gotcha §3.1: ".inputmethod." interior label)

    func testHelperBundleIDHasInputMethodInteriorLabel() {
        XCTAssertTrue(IMKMessaging.helperBundleID.contains(".inputmethod."),
                      "the login-time scanner only classifies bundles with a .inputmethod. interior label as input methods")
    }

    func testConnectionNameMatchesBundleConvention() {
        XCTAssertEqual(IMKMessaging.connectionName, IMKMessaging.helperBundleID + "_Connection")
    }

    // MARK: - Engagement-mode persistence (snapshot migration)

    func testEngagementModeCodableRoundTrip() throws {
        for mode in IMKEngagementMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(IMKEngagementMode.self, from: data), mode)
        }
    }

    func testEngagementModeRawValuesStable() {
        // Persisted in settings.json — keep the raw values stable across versions.
        XCTAssertEqual(IMKEngagementMode.alwaysOn.rawValue, "alwaysOn")
        XCTAssertEqual(IMKEngagementMode.justInTime.rawValue, "justInTime")
    }
}
