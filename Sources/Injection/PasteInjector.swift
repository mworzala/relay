import AppKit
import Carbon.HIToolbox
import Foundation

/// Finalizes a dictation in "Overlay + paste" mode by placing the final text on the
/// clipboard and posting ⌘V, then restoring the previous clipboard.
///
/// Nothing is written to the field during streaming (the live transcript lives in
/// Relay's overlay), so ⌘V inserts at the user's *real* caret — correct for blank,
/// end-of-field, and mid-field — routing through the app's native edit pipeline.
/// That gives a clean caret landing and a single undo for free, sidestepping the
/// Chromium/Electron AX problems that the direct injector fights. No caret repair
/// is needed: this mode never moved the caret.
///
/// `nonisolated` + `@unchecked Sendable`: all pasteboard + CGEvent work runs on a
/// private serial queue, off the main actor, mirroring the other injectors.
///
/// Known limitation: if the process is *abnormally* terminated (crash / SIGKILL)
/// during the brief restore window below, the last dictated text is left on the
/// clipboard and the prior contents aren't restored. This is inherent to
/// clipboard-based paste injection — a signal handler can't safely call
/// `NSPasteboard`, and a graceful quit landing inside the sub-second window is
/// negligible — so it's accepted rather than guarded.
nonisolated final class PasteInjector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mattworzala.paste-injector")

    /// How long to give the target to consume the paste before restoring the prior
    /// clipboard. A ⌘V is a *read*, which doesn't bump `changeCount`, so we can't
    /// observe consumption directly — we wait a fixed window. Tuned conservatively
    /// toward paste-correctness: restoring before a slow target (busy Electron, a VM,
    /// a remote field) has read the board would make it paste the user's *old*
    /// clipboard. The cost of waiting longer is benign — the `changeCount` guard
    /// below still declines to clobber anything the user copies in the meantime.
    /// (TODO: measure against a slow Electron target per the plan's verification.)
    private static let restoreDelay: TimeInterval = 0.5

    private static let tracing = RelayDebug.injectTracing

    /// Paste `finalText` at the user's caret, restoring the prior clipboard after.
    /// No-op for empty text or under secure input. Returns immediately; the work
    /// runs on the serial queue.
    func paste(_ finalText: String) {
        queue.async { Self.run(finalText) }
    }

    private static func run(_ finalText: String) {
        guard !finalText.isEmpty else { return }
        // Secure input (e.g. a password field): don't touch the clipboard or paste —
        // ⌘V would be swallowed and we'd needlessly churn the user's clipboard.
        guard !IsSecureEventInputEnabled() else {
            trace("secure input — skipping paste")
            return
        }

        let saved = Clipboard.save()
        let afterWrite = Clipboard.setStringForPaste(finalText)
        SyntheticKeys.paste()
        trace("pasted \(finalText.utf16.count) UTF-16 units")

        // Let the target consume the paste, then restore — but only if nothing else
        // wrote to the board meanwhile. A changed `changeCount` means the user (or
        // the app) copied something new since our write, and restoring the old
        // snapshot would clobber it; leave the newer content in place.
        Thread.sleep(forTimeInterval: restoreDelay)
        if shouldRestore(afterWrite: afterWrite, current: NSPasteboard.general.changeCount) {
            Clipboard.restore(saved)
            trace("restored prior clipboard")
        } else {
            trace("clipboard changed during paste — leaving newer contents")
        }
    }

    /// Whether to restore the prior clipboard: only when nothing wrote to the board
    /// since our paste write (an unchanged count). A changed count means a competing
    /// copy we must not clobber. Extracted so the decision is unit-testable.
    static func shouldRestore(afterWrite: Int, current: Int) -> Bool {
        current == afterWrite
    }

    private static func trace(_ message: @autoclosure () -> String) {
        if tracing { NSLog("Relay/paste-injector: \(message())") }
    }
}
