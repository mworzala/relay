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
            // Consistency check is case-insensitive to match the agreement above —
            // a capitalization flip on a settled word must not delay its commit by a
            // pass. Keep the already-committed words' casing (append only the newly
            // agreed ones) so confirmed text never visually changes.
            if confirmed.isEmpty || sharedPrefixCount(candidate, confirmed) == confirmed.count {
                newConfirmed = confirmed + candidate[confirmed.count...]
            }
        }

        // Slice the volatile tail from where the current hypothesis stops matching
        // the committed prefix — NOT blindly at committedCount. Because each pass
        // re-transcribes the whole growing buffer, Parakeet can revise an
        // already-committed early word as more right-context arrives (committed
        // [the, cat], next [the, dog, sat]); indexing past that divergence would
        // silently drop "dog" live. Slicing at the shared-prefix length keeps every
        // current word visible; the committed prefix stays locked and the
        // authoritative final pass reconciles any locked/current conflict.
        let volatileStart = sharedPrefixCount(curr, newConfirmed)
        let volatile = curr.count > volatileStart ? Array(curr[volatileStart...]) : []
        return (newConfirmed, volatile)
    }

    /// One step plus the **coherent display split** for the live preview.
    ///
    /// `step` keeps the locked prefix monotonic (good for off-mode injection) but its
    /// `confirmed`+`volatile` can DUPLICATE text on screen: when curr revises an
    /// already-committed word, the locked tail stays in `confirmed` while the revised
    /// words reappear at the head of `volatile` (e.g. committed "…weird duplication",
    /// volatile "weird duplication going on"). For display we instead partition the
    /// *current* hypothesis itself: `confirmed` is curr's leading agreement with the
    /// locked prefix and `volatile` is the rest, so `confirmed + volatile == curr`
    /// always — no duplication, nothing dropped. `committed` is the locked prefix,
    /// returned separately for off-mode (which must stay monotonic).
    static func displayStep(prev: [String], curr: [String], committed: [String])
        -> (committed: [String], confirmed: [String], volatile: [String]) {
        let r = step(prev: prev, curr: curr, confirmed: committed)
        // volatile == curr[shown...], so shown == curr.count - volatile.count.
        let shown = curr.count - r.volatile.count
        return (committed: r.confirmed, confirmed: Array(curr.prefix(shown)), volatile: r.volatile)
    }

    /// Length of the longest case-insensitive shared word-prefix of `a` and `b`.
    private static func sharedPrefixCount(_ a: [String], _ b: [String]) -> Int {
        var n = 0
        let bound = min(a.count, b.count)
        while n < bound, a[n].lowercased() == b[n].lowercased() { n += 1 }
        return n
    }
}
