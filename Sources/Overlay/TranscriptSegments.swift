import Foundation

/// Splits a live hypothesis into a committed **head** (rendered at full strength)
/// and a volatile **tail** (de-emphasized) for the transcript overlay.
///
/// Pure value type — no UI — so the head/tail/spacing logic unit-tests in
/// isolation. Mirrors how the direct injector joins the committed prefix and the
/// volatile tail (a single separating space when both are present).
nonisolated struct TranscriptSegments: Equatable, Sendable {
    /// Fully-committed text — rendered at full opacity.
    let head: String
    /// Volatile / low-confidence tail — rendered de-emphasized. Carries a single
    /// leading space when a head is present, so head + tail reads naturally without
    /// the view special-casing spacing.
    let tail: String

    init(confirmed: String, volatile: String) {
        let c = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        head = c
        tail = (!c.isEmpty && !v.isEmpty) ? " " + v : v
    }

    /// Nothing to display.
    var isEmpty: Bool { head.isEmpty && tail.isEmpty }

    /// The full one-string transcript (head + tail), for measurement / accessibility.
    var combined: String { head + tail }
}
