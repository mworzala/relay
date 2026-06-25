import Foundation

/// Pure, testable detector for a **double-tap** of the hold-to-talk key, used to
/// reconcile two gestures that both begin with a key-down:
///   - *hold* — press, speak while held, release to finalize (the default);
///   - *double-tap to latch* — two quick taps start a hands-free session that
///     keeps listening after the key is released, until the next tap stops it.
///
/// A "tap" here is a press that was released **before dictation began** (during
/// the arm delay — see `DictationController`), so the first tap never dictates a
/// stray word. The tracker only answers one question: *is this press the second
/// half of a double-tap?* — i.e. did a prior quick tap occur within the window.
/// Time is injected (monotonic seconds) so it's deterministic under test.
nonisolated struct DoubleTapTracker {
    /// Max seconds between the two taps' key-down events to count as a double-tap.
    var windowSeconds: Double

    /// Press time of an unconsumed quick tap (the potential first half), or nil.
    private var pendingTapPressTime: Double?
    /// Time of the most recent `registerPress`, promoted to `pendingTapPressTime`
    /// by `registerQuickTap` if that press turns out to be a quick tap.
    private var lastPressTime: Double = 0

    init(windowSeconds: Double = 0.35) { self.windowSeconds = windowSeconds }

    /// Record a key-down at `time`. Returns true iff a prior quick tap is still
    /// within the window — i.e. this press is the second tap of a double-tap.
    /// Consumes the pending tap either way (so a third press isn't paired again).
    mutating func registerPress(at time: Double) -> Bool {
        let isSecondTap = pendingTapPressTime.map { time - $0 <= windowSeconds } ?? false
        pendingTapPressTime = nil
        lastPressTime = time
        return isSecondTap
    }

    /// The most recent press was released before dictation began (a quick tap).
    /// Arm it as the potential first half of a double-tap for the next press.
    mutating func registerQuickTap() { pendingTapPressTime = lastPressTime }

    /// Forget any pending tap (after a latched session starts or is stopped, or the
    /// bind changes) so an unrelated future press isn't mis-paired into a latch.
    mutating func reset() { pendingTapPressTime = nil }
}
