import XCTest
@testable import Relay

/// Grapheme-based minimal-edit diff for the keystroke fallback (`TextDiff`).
/// `nonisolated` per the MainActor-default rule.
nonisolated final class TextDiffTests: XCTestCase {

    func testAppendOnlyInsertsTail() {
        let plan = TextDiff.plan(typed: "Hello", target: "Hello world")
        XCTAssertEqual(plan, TextDiff.Plan(backspaces: 0, insert: " world"))
    }

    func testLowercaseToCapitalizedCorrection() {
        // Mirrors the relay-asr-probe inject-test: 5 backspaces, retype the suffix.
        let plan = TextDiff.plan(typed: "Welcome to relay", target: "Welcome to Relay,")
        XCTAssertEqual(plan, TextDiff.Plan(backspaces: 5, insert: "Relay,"))
    }

    func testGraphemeCommonPrefixCount() {
        // 'é' is one grapheme; it differs from 'e', so the common prefix is "caf" (3).
        XCTAssertEqual(TextDiff.commonPrefixCount("café", "cafe"), 3)
    }

    func testApplyRoundTrips() {
        let plan = TextDiff.plan(typed: "abcXY", target: "abcZ")
        XCTAssertEqual(TextDiff.apply(plan, to: "abcXY"), "abcZ")
    }
}
