import Foundation

/// Pure, testable minimal-edit diff for the injector. Given what we've already
/// typed and the new desired text, returns how many trailing characters to delete
/// (Backspaces) and what to type after them. Because only the volatile tail of an
/// ASR hypothesis ever changes, the common prefix is large and the edit is tiny.
///
/// `nonisolated` so the off-main `TextInjector` can call it.
nonisolated enum TextDiff {
    struct Plan: Equatable {
        let backspaces: Int
        let insert: String
    }

    static func plan(typed: String, target: String) -> Plan {
        let common = commonPrefixCount(typed, target)
        let backspaces = typed.count - common
        let insert = String(target.dropFirst(common))
        return Plan(backspaces: backspaces, insert: insert)
    }

    /// Number of leading grapheme clusters two strings share. Counting by
    /// Character (not UTF-16) keeps Backspace counts correct — one Delete key press
    /// removes one grapheme.
    static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var ai = a.startIndex
        var bi = b.startIndex
        while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
            count += 1
            ai = a.index(after: ai)
            bi = b.index(after: bi)
        }
        return count
    }

    /// Apply a plan to a model string (used by tests and to keep `typed` in sync).
    static func apply(_ plan: Plan, to typed: String) -> String {
        String(typed.dropLast(plan.backspaces)) + plan.insert
    }
}
