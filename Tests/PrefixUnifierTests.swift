import XCTest
@testable import Relay

/// Tier-1 prefix-unification rules as pure `(prefix, dictation) -> expected` cases.
/// `nonisolated` because the project defaults types to the MainActor.
nonisolated final class PrefixUnifierTests: XCTestCase {

    // MARK: unify (integration)

    func testNilPrefixIsVerbatim() {
        XCTAssertEqual(PrefixUnifier.unify(prefix: nil, dictation: "hello world"), "hello world")
    }

    func testEmptyPrefixCapitalizesNoLeadingSpace() {
        XCTAssertEqual(PrefixUnifier.unify(prefix: "", dictation: "hello world"), "Hello world")
    }

    func testMidSentenceAddsSpaceKeepsCasing() {
        XCTAssertEqual(PrefixUnifier.unify(prefix: "I went to the", dictation: "store"), " store")
    }

    func testAfterTerminatorCapitalizesAndSpaces() {
        XCTAssertEqual(PrefixUnifier.unify(prefix: "Hello.", dictation: "world"), " World")
    }

    func testOverlapDroppedThenSpaced() {
        XCTAssertEqual(PrefixUnifier.unify(prefix: "I love", dictation: "love coding"), " coding")
    }

    func testFullDuplicateIsKeptNotErased() {
        // A pure echo is ambiguous; keeping it (rather than erasing to "") avoids
        // silent data loss and live-seam flicker.
        XCTAssertEqual(PrefixUnifier.unify(prefix: "see you later", dictation: "you later"), " you later")
    }

    func testTrailingSpaceWhenInsertingBeforeWord() {
        // Caret in the middle of "Hello world": prefix "Hello ", nextChar 'w'.
        XCTAssertEqual(
            PrefixUnifier.unify(prefix: "Hello ", dictation: "there", nextChar: "w"),
            "there ")
    }

    // MARK: dedup

    func testDedupSingleLongToken() {
        XCTAssertEqual(PrefixUnifier.applyDedup(prefix: "I love", dictation: "love coding"), "coding")
    }

    func testDedupRejectsShortSingleToken() {
        // "fox" is 3 chars (< minLongToken) → not dropped, to avoid common-word noise.
        XCTAssertEqual(
            PrefixUnifier.applyDedup(prefix: "the quick brown fox", dictation: "fox jumps"),
            "fox jumps")
    }

    func testDedupMultiToken() {
        XCTAssertEqual(
            PrefixUnifier.applyDedup(prefix: "go to the store", dictation: "to the store now"),
            "now")
    }

    func testDedupCaseInsensitive() {
        XCTAssertEqual(
            PrefixUnifier.applyDedup(prefix: "The Store", dictation: "store is closed"),
            "is closed")
    }

    func testDedupPunctuationInsensitive() {
        XCTAssertEqual(
            PrefixUnifier.applyDedup(prefix: "I said hello.", dictation: "hello there"),
            "there")
    }

    func testDedupNoOverlap() {
        XCTAssertEqual(PrefixUnifier.applyDedup(prefix: "hello", dictation: "world"), "world")
    }

    func testDedupKeepsSymbolOnlyTokens() {
        // Pure-symbol tokens normalize to "" and must not match each other.
        XCTAssertEqual(PrefixUnifier.applyDedup(prefix: ":) :)", dictation: ":) :) hi"), ":) :) hi")
    }

    func testDedupRequiresSurvivingWord() {
        // Full echo → no surviving word → keep the dictation rather than erase it.
        XCTAssertEqual(PrefixUnifier.applyDedup(prefix: "you later", dictation: "you later"), "you later")
    }

    // MARK: capitalization

    func testCapitalizeAtFieldStart() {
        XCTAssertEqual(PrefixUnifier.applyCapitalization(prefix: "", dictation: "hello"), "Hello")
    }

    func testCapitalizeAfterTerminator() {
        XCTAssertEqual(PrefixUnifier.applyCapitalization(prefix: "Hello.", dictation: "world"), "World")
    }

    func testCapitalizeAfterTerminatorAndTrailingSpace() {
        XCTAssertEqual(PrefixUnifier.applyCapitalization(prefix: "Hello. ", dictation: "world"), "World")
    }

    func testCapitalizeAfterClosingQuote() {
        XCTAssertEqual(
            PrefixUnifier.applyCapitalization(prefix: "He said \"go.\"", dictation: "now"),
            "Now")
    }

    func testNoCapitalizeMidSentence() {
        XCTAssertEqual(PrefixUnifier.applyCapitalization(prefix: "the value is", dictation: "five"), "five")
    }

    func testNeverLowercasesProperNoun() {
        XCTAssertEqual(PrefixUnifier.applyCapitalization(prefix: "we visited", dictation: "Paris"), "Paris")
    }

    // MARK: spacing

    func testSpacingInsertsSeam() {
        XCTAssertEqual(PrefixUnifier.applySpacing(prefix: "Hello", dictation: "world", nextChar: nil), " world")
    }

    func testSpacingSkipsWhenPrefixEndsInSpace() {
        XCTAssertEqual(PrefixUnifier.applySpacing(prefix: "Hello ", dictation: "world", nextChar: nil), "world")
    }

    func testSpacingSkipsBeforeAttachingPunctuation() {
        XCTAssertEqual(PrefixUnifier.applySpacing(prefix: "Hello", dictation: ", world", nextChar: nil), ", world")
    }

    func testSpacingSkipsForEmptyPrefix() {
        XCTAssertEqual(PrefixUnifier.applySpacing(prefix: "", dictation: "world", nextChar: nil), "world")
    }

    func testSpacingNoTrailingWhenNextCharIsSpace() {
        XCTAssertEqual(PrefixUnifier.applySpacing(prefix: "Hello", dictation: "world", nextChar: " "), " world")
    }

    func testSpacingCollapsesInternalDoubles() {
        XCTAssertEqual(PrefixUnifier.applySpacing(prefix: "end", dictation: "well  done", nextChar: nil), " well done")
    }

    func testSpacingCollapsesDoubledSeam() {
        // Prefix already ends in space; a leading dictation space would double it.
        XCTAssertEqual(PrefixUnifier.applySpacing(prefix: "Hello ", dictation: "  world", nextChar: nil), "world")
    }
}
