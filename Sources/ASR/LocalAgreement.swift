import Foundation

/// The LocalAgreement-2 commit rule, extracted as a pure value transform so the
/// single most behavior-defining algorithm in the app can be unit-tested in
/// isolation (it was previously entangled with `@MainActor`, the ASR manager,
/// four instance vars, and the `onUpdate` side effect).
///
/// `nonisolated` + side-effect-free: given the previous and current word
/// hypotheses and the already-committed prefix, it returns the (possibly grown)
/// committed prefix and the volatile tail.
nonisolated enum LocalAgreement {
    /// One LocalAgreement-2 step.
    ///
    /// - The committed prefix grows to the longest word-prefix the last two
    ///   hypotheses agree on (case-insensitively), but only ever grows and never
    ///   diverges from what is already committed (so confirmed text is stable).
    /// - The volatile tail is everything in the current hypothesis after the
    ///   committed prefix.
    static func step(prev: [String], curr: [String], confirmed: [String])
        -> (confirmed: [String], volatile: [String]) {
        // Longest word-prefix the last two hypotheses agree on (case-insensitive,
        // matching how the volatile tail self-corrects capitalization).
        var agree = 0
        let bound = min(prev.count, curr.count)
        while agree < bound, prev[agree].lowercased() == curr[agree].lowercased() {
            agree += 1
        }

        // Grow the committed prefix only, and only when consistent with what's
        // already committed (so confirmed text never changes or shrinks).
        var newConfirmed = confirmed
        if agree > confirmed.count {
            let candidate = Array(curr.prefix(agree))
            if confirmed.isEmpty || candidate.starts(with: confirmed) {
                newConfirmed = candidate
            }
        }

        let committedCount = newConfirmed.count
        let volatile = curr.count > committedCount ? Array(curr[committedCount...]) : []
        return (newConfirmed, volatile)
    }
}
