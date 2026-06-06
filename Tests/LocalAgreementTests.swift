import XCTest
@testable import Relay

/// Unit coverage for the LocalAgreement-2 commit rule — the highest-risk algorithm
/// in the app, deciding what live text gets committed on every update.
nonisolated final class LocalAgreementTests: XCTestCase {
    private func step(_ prev: [String], _ curr: [String], _ confirmed: [String])
        -> (confirmed: [String], volatile: [String]) {
        LocalAgreement.step(prev: prev, curr: curr, confirmed: confirmed)
    }

    func testFirstHypothesisHasNoPriorAgreementSoAllVolatile() {
        // No previous hypothesis to agree with → nothing committed yet.
        let r = step([], ["the", "cat"], [])
        XCTAssertEqual(r.confirmed, [])
        XCTAssertEqual(r.volatile, ["the", "cat"])
    }

    func testAgreementAcrossTwoHypothesesCommitsThePrefix() {
        let r = step(["the", "cat", "sat"], ["the", "cat", "ran"], [])
        XCTAssertEqual(r.confirmed, ["the", "cat"])
        XCTAssertEqual(r.volatile, ["ran"])
    }

    func testConfirmedNeverShrinks() {
        // A shorter current hypothesis cannot retract already-committed words.
        let r = step(["the", "cat"], ["the"], ["the", "cat"])
        XCTAssertEqual(r.confirmed, ["the", "cat"])
    }

    func testConfirmedGrowsMonotonically() {
        let r = step(["the", "cat", "sat", "down"], ["the", "cat", "sat", "still"],
                     ["the", "cat"])
        XCTAssertEqual(r.confirmed, ["the", "cat", "sat"])
        XCTAssertEqual(r.volatile, ["still"])
    }

    func testAgreementIsCaseInsensitive() {
        // Capitalization differences across passes still count as agreement.
        let r = step(["The", "Cat"], ["the", "cat", "sat"], [])
        XCTAssertEqual(r.confirmed, ["the", "cat"])
        XCTAssertEqual(r.volatile, ["sat"])
    }

    func testEmptyCurrentYieldsEmptyVolatile() {
        let r = step(["the"], [], ["the"])
        XCTAssertEqual(r.volatile, [])
    }

    func testCapitalizationFlipDoesNotDelayCommit() {
        // "the" is committed lowercase; the agreeing passes capitalize it ("The")
        // and agree on a following "cat". A case-sensitive guard used to refuse to
        // commit "cat" for a pass; now it commits immediately, and the committed
        // casing of "the" is preserved.
        let r = step(["The", "cat", "x"], ["The", "cat", "y"], ["the"])
        XCTAssertEqual(r.confirmed, ["the", "cat"])
        XCTAssertEqual(r.volatile, ["y"])
    }

    func testRevisedCommittedWordIsNotDroppedFromVolatile() {
        // [the, cat] is already committed; a later pass revises "cat" → "dog" and
        // extends with "sat". The committed prefix stays locked, but the revised
        // "dog" must remain visible in the volatile tail rather than being sliced
        // away by a stale index (which would render "the cat sat", dropping "dog").
        let r = step(["the", "cat"], ["the", "dog", "sat"], ["the", "cat"])
        XCTAssertEqual(r.confirmed, ["the", "cat"])
        XCTAssertEqual(r.volatile, ["dog", "sat"])
    }
}
