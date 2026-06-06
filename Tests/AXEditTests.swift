import XCTest
@testable import Relay

/// UTF-16 range math for AX replacement (`AXEdit.compute`). No live AX — pure
/// arithmetic over previously-inserted vs new text. `nonisolated` per the
/// MainActor-default rule.
nonisolated final class AXEditTests: XCTestCase {

    func testFirstInsertAtCaret() {
        let e = AXEdit.compute(previous: "", next: "Hello", insertionStart: 10)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 10, length: 0),
                                 replacement: "Hello", caretAfter: 15, insertedLength: 5))
    }

    func testAppendToTailReplacesOnlyNewSuffix() {
        let e = AXEdit.compute(previous: "Hello", next: "Hello world", insertionStart: 10)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 15, length: 0),
                                 replacement: " world", caretAfter: 21, insertedLength: 11))
    }

    func testMiddleChangeUsesCommonPrefixAndSuffix() {
        // "the cat sat" -> "the dog sat": only "cat" (offset 4, len 3) is replaced.
        let e = AXEdit.compute(previous: "the cat sat", next: "the dog sat", insertionStart: 0)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 4, length: 3),
                                 replacement: "dog", caretAfter: 7, insertedLength: 11))
    }

    func testShrinkDeletesChangedRun() {
        // "helllo" -> "hello": delete the extra 'l' at offset 4.
        let e = AXEdit.compute(previous: "helllo", next: "hello", insertionStart: 0)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 4, length: 1),
                                 replacement: "", caretAfter: 4, insertedLength: 5))
    }

    func testIdenticalIsEmptyEdit() {
        let e = AXEdit.compute(previous: "same", next: "same", insertionStart: 3)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 7, length: 0),
                                 replacement: "", caretAfter: 7, insertedLength: 4))
    }

    func testEmojiCountsAsTwoUTF16Units() {
        // "👍" is a surrogate pair → 2 UTF-16 units; lengths/offsets must be UTF-16.
        let e = AXEdit.compute(previous: "hi", next: "hi👍", insertionStart: 0)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 2, length: 0),
                                 replacement: "👍", caretAfter: 4, insertedLength: 4))
    }

    func testCJKUTF16Lengths() {
        let e = AXEdit.compute(previous: "", next: "你好", insertionStart: 5)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 5, length: 0),
                                 replacement: "你好", caretAfter: 7, insertedLength: 2))
    }

    func testSurrogateSubstitutionDoesNotSplitPair() {
        // 😀 (D83D DE00) -> 😁 (D83D DE01) share the high surrogate. Without
        // boundary snapping the diff would replace 1 unit at a mid-pair offset and
        // write a lone surrogate (→ U+FFFD). The whole pair must be replaced.
        let e = AXEdit.compute(previous: "a😀", next: "a😁", insertionStart: 0)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 1, length: 2),
                                 replacement: "😁", caretAfter: 3, insertedLength: 3))
        XCTAssertFalse(e.replacement.unicodeScalars.contains("\u{FFFD}"))
    }

    func testSurrogateSubstitutionWithCommonSuffix() {
        let e = AXEdit.compute(previous: "x😀y", next: "x😁y", insertionStart: 0)
        XCTAssertEqual(e, AXEdit(range: NSRange(location: 1, length: 2),
                                 replacement: "😁", caretAfter: 3, insertedLength: 4))
    }

    // MARK: AXText.splicedValue (Chromium/Electron whole-value write path)

    func testSplicedValueInsertAtCaret() {
        XCTAssertEqual(
            AXText.splicedValue("Hello world", insertionStart: 5, regionLength: 0, target: " there"),
            "Hello there world")
    }

    func testSplicedValueReplacesRegion() {
        XCTAssertEqual(
            AXText.splicedValue("abcdef", insertionStart: 2, regionLength: 2, target: "XY"),
            "abXYef")
    }

    func testSplicedValueReplacesWholeRegion() {
        XCTAssertEqual(
            AXText.splicedValue("old text", insertionStart: 0, regionLength: 8, target: "new"),
            "new")
    }

    func testSplicedValueClampsOutOfBounds() {
        XCTAssertEqual(
            AXText.splicedValue("ab", insertionStart: 10, regionLength: 5, target: "X"),
            "abX")
    }

    func testSplicedValueUTF16Emoji() {
        // insertionStart is a UTF-16 offset; "hi" is 2 units.
        XCTAssertEqual(
            AXText.splicedValue("hi", insertionStart: 2, regionLength: 0, target: "👍"),
            "hi👍")
    }

    func testSplicedValueDoesNotSplitSurrogatePairAtStart() {
        // insertionStart 2 lands on the low half of 😀 (a,D83D,DE00,b). Without
        // boundary snapping the slice would leave a lone high+low surrogate around the
        // target (→ U+FFFD). The boundary must snap so the emoji survives intact.
        let r = AXText.splicedValue("a😀b", insertionStart: 2, regionLength: 0, target: "X")
        XCTAssertFalse(r.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertEqual(r, "aX😀b")
    }

    func testSplicedValueDoesNotSplitSurrogatePairAtEnd() {
        // The region end (1+1=2) bisects 😀; it must snap so no lone surrogate remains.
        let r = AXText.splicedValue("a😀b", insertionStart: 1, regionLength: 1, target: "X")
        XCTAssertFalse(r.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertEqual(r, "aX😀b")
    }
}
