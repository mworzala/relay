import Foundation

/// Single source of truth for how Relay counts "words". Splitting on spaces,
/// newlines, and tabs mirrors what the ASR layer commits, so the count used for
/// stats can never drift from the count the streaming transcriber works in.
///
/// `nonisolated` so off-main callers (the pure `DictationStats` aggregator, the
/// SwiftData `Transcription` model) can use it without hopping to `@MainActor`.
nonisolated enum WordCount {
    /// Split `text` into words: any run of space / newline / tab is a separator.
    /// Leading/trailing/duplicate whitespace yields no empty tokens.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// Number of words in `text` (same definition as `words`), without allocating
    /// the intermediate `[String]`.
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
