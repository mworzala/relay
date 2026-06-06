import Foundation

/// Tier-1 deterministic unification of freshly-dictated text with the text that
/// already precedes the caret (the "prefix"). Pure string functions — no AX, no
/// side effects — so each rule unit-tests as `(prefix, dictation) -> expected`.
///
/// Applied as the **last** step before injection, on every render (so the seam
/// stays stable as the volatile ASR tail rewrites). Returns the dictation
/// **unchanged when `prefix == nil`** — the keystroke fallback usually has no
/// prefix and inserts verbatim.
///
/// The three rules are robust to whatever casing/punctuation the model emits:
/// capitalization only ever *adds* a leading capital (after a sentence terminator
/// or at field start) and never lowercases, so if Parakeet already capitalizes,
/// the rule is a no-op.
///
/// Higher tiers (NaturalLanguage sentence detection; LLM rewrite) are intentionally
/// out of scope — this structure lets a smarter unifier slot in later.
nonisolated enum PrefixUnifier {
    /// Punctuation that should hug the preceding word (no seam space before it).
    private static let attaching: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]
    /// Sentence terminators that imply the next word should be capitalized.
    private static let terminators: Set<Character> = [".", "!", "?"]
    /// Closing quotes/brackets allowed to trail a terminator while still ending a
    /// sentence (whitespace is handled separately).
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}"]
    /// Minimum length for a *single*-token overlap to count as a real duplicate
    /// (avoids dropping common short words like "the"/"and"/"to").
    private static let minLongToken = 4

    /// Unify `dictation` so it reads naturally after `prefix`. `nextChar` is the
    /// character immediately after the caret (used to keep a space when inserting
    /// into the middle of existing text). Returns the text to insert at the caret.
    static func unify(prefix: String?, dictation: String, nextChar: Character? = nil) -> String {
        guard let prefix else { return dictation }   // no AX prefix → insert verbatim
        var text = dictation
        text = applyDedup(prefix: prefix, dictation: text)
        text = applyCapitalization(prefix: prefix, dictation: text)
        text = applySpacing(prefix: prefix, dictation: text, nextChar: nextChar)
        return text
    }

    // MARK: Rule 2 — dedup / overlap

    /// Drop a leading run of `dictation` words that duplicate the tail of `prefix`
    /// (case-insensitive, punctuation-insensitive). Requires ≥2 overlapping tokens,
    /// or a single token of length ≥ `minLongToken`, to avoid false positives.
    static func applyDedup(prefix: String, dictation: String) -> String {
        // Use the single word-split source of truth (space/newline/tab) so dedup
        // tokenizes identically to what the ASR layer commits and the stats count.
        let prefixWords = WordCount.words(prefix)
        let dictWords = WordCount.words(dictation)
        guard !prefixWords.isEmpty, !dictWords.isEmpty else { return dictation }

        let tail = prefixWords.suffix(6).map(normalizedToken)
        let head = dictWords.map(normalizedToken)
        let maxK = min(tail.count, head.count)

        var overlap = 0
        var k = maxK
        while k >= 1 {
            let tailSlice = Array(tail.suffix(k))
            // Exclude empty normalized tokens: pure-symbol tokens (":)", "[", "--")
            // all normalize to "" and would spuriously match each other, deleting
            // real dictated content.
            if tailSlice == Array(head.prefix(k)), !tailSlice.contains("") { overlap = k; break }
            k -= 1
        }
        guard overlap > 0 else { return dictation }
        if overlap == 1, head[0].count < minLongToken { return dictation }   // too-common single word
        // Require at least one surviving word: never erase the whole dictation. A
        // full echo is ambiguous, and on the live stream the would-be-erased text
        // appears then reappears as the word completes (seam flicker). Keeping it is
        // safer than silently dropping everything.
        guard overlap < dictWords.count else { return dictation }

        return dictWords.dropFirst(overlap).joined(separator: " ")
    }

    /// Lowercased, with surrounding (not internal) punctuation stripped — for
    /// overlap comparison only.
    private static func normalizedToken(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: Rule 3 — capitalization

    /// Capitalize the dictation's first letter if the prefix is empty/blank or ends
    /// a sentence. Mid-sentence the model's casing is left alone (never lowercased —
    /// proper nouns).
    static func applyCapitalization(prefix: String, dictation: String) -> String {
        guard !dictation.isEmpty, shouldCapitalize(after: prefix) else { return dictation }
        return uppercasingFirst(dictation)
    }

    private static func shouldCapitalize(after prefix: String) -> Bool {
        // Walk back over trailing whitespace + closing quotes/brackets to the last
        // meaningful character. Empty/blank prefix → sentence start → capitalize.
        var idx = prefix.endIndex
        while idx > prefix.startIndex {
            let prev = prefix.index(before: idx)
            let ch = prefix[prev]
            if ch.isWhitespace || closers.contains(ch) { idx = prev; continue }
            return terminators.contains(ch)
        }
        return true
    }

    private static func uppercasingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: Rule 1 — spacing

    /// Insert a single seam space when the prefix doesn't end in whitespace and the
    /// dictation doesn't start with whitespace or attaching punctuation. When the
    /// caret sits before existing word text (`nextChar`), also keep a trailing space
    /// so the dictation doesn't fuse onto it.
    static func applySpacing(prefix: String, dictation: String, nextChar: Character?) -> String {
        guard !dictation.isEmpty else { return dictation }
        var text = collapsingSpaces(dictation)   // collapse accidental internal doubles

        if prefix.last?.isWhitespace ?? false {
            // Prefix already supplies the separating space — drop any leading space
            // so the seam isn't doubled.
            while text.first == " " { text.removeFirst() }
        } else if !prefix.isEmpty, let firstDict = text.first,
                  !firstDict.isWhitespace, !attaching.contains(firstDict) {
            text = " " + text
        }

        if let next = nextChar, isWord(next), let last = text.last, isWord(last) {
            text += " "
        }
        return text
    }

    /// Collapse runs of 2+ plain spaces to one (leaves tabs/newlines intact).
    private static func collapsingSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}
