import XCTest
@testable import Relay

/// The committed/volatile split that feeds the transcript overlay. Pure string
/// logic — no UI. `nonisolated` per the MainActor-default rule.
nonisolated final class TranscriptSegmentsTests: XCTestCase {

    func testBothPresentJoinWithSingleSpace() {
        let s = TranscriptSegments(confirmed: "Hello there", volatile: "general")
        XCTAssertEqual(s.head, "Hello there")
        XCTAssertEqual(s.tail, " general")   // leading separator space
        XCTAssertEqual(s.combined, "Hello there general")
        XCTAssertFalse(s.isEmpty)
    }

    func testConfirmedOnlyHasNoTail() {
        let s = TranscriptSegments(confirmed: "Just this", volatile: "")
        XCTAssertEqual(s.head, "Just this")
        XCTAssertEqual(s.tail, "")
        XCTAssertEqual(s.combined, "Just this")
    }

    func testVolatileOnlyHasNoLeadingSpace() {
        let s = TranscriptSegments(confirmed: "", volatile: "starting")
        XCTAssertEqual(s.head, "")
        XCTAssertEqual(s.tail, "starting")   // no head → no separator
        XCTAssertEqual(s.combined, "starting")
    }

    func testWhitespaceTrimmedOnEachSide() {
        let s = TranscriptSegments(confirmed: "  Hello  ", volatile: "  world  ")
        XCTAssertEqual(s.head, "Hello")
        XCTAssertEqual(s.tail, " world")
        XCTAssertEqual(s.combined, "Hello world")
    }

    func testEmptyIsEmpty() {
        let s = TranscriptSegments(confirmed: "   ", volatile: "\n")
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.combined, "")
    }
}
