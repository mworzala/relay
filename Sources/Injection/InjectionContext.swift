import ApplicationServices
import Foundation

/// Which mechanism the coordinator chose for the current dictation session.
/// Surfaced in the debug diagnostics strip.
nonisolated enum InjectionMode: String, Sendable, Equatable {
    /// Accessibility direct text manipulation (primary).
    case ax
    /// Synthetic CGEvent keystrokes (fallback).
    case keystroke
    /// Secure input is active (e.g. a password field) — inject nothing.
    case secure
}

/// Immutable, per-session context resolved at `beginSession` time and handed to
/// the chosen injection strategy.
///
/// **Units:** every offset/length here is **UTF-16 (NSString) units**, matching
/// the Accessibility text APIs — *not* grapheme clusters. Do not mix with
/// `TextDiff`'s grapheme counting.
///
/// `@unchecked Sendable`: it carries an `AXUIElement` (a CoreFoundation type that
/// is not itself `Sendable`); access is confined to the injector's serial queue,
/// so passing the value across queues is safe in practice.
nonisolated struct InjectionContext: @unchecked Sendable {
    /// The focused element resolved at session start (nil if none / unresolved).
    let element: AXUIElement?
    /// Owning application's process id (0 if unknown).
    let pid: pid_t
    /// Bundle identifier of the target app, if resolvable.
    let bundleID: String?
    /// Localized app name (for the debug strip); falls back to bundle id.
    let appName: String
    /// UTF-16 offset of the caret at session start — where dictation begins.
    let caretLocation: Int
    /// Bounded text immediately before the caret at session start (≤ a small cap,
    /// UTF-16). Frozen — never re-read mid-session (our own insertions follow the
    /// caret, so a re-read would read our output back). **Sensitive:** never log
    /// its contents, only its length. `nil` means "no prefix available" → callers
    /// insert the dictation verbatim.
    let prefix: String?
    /// The single character immediately *after* the caret at start, if any — used
    /// for trailing-space decisions when inserting into the middle of a field.
    let nextChar: Character?
    /// Best-effort sink for a one-line "last operation" summary, pushed to the
    /// debug overlay. `nil` when diagnostics are disabled. Must be `@Sendable`:
    /// it is invoked from off-main injector queues.
    let report: (@Sendable (String) -> Void)?
    /// Invoked by the AX strategy if its **first** write fails — i.e. nothing was
    /// inserted yet, so a clean keystroke retry is safe. The coordinator wires this
    /// to re-route the session to the keystroke fallback. `@Sendable`: called from
    /// the off-main AX queue.
    let fallback: (@Sendable () -> Void)?

    init(
        element: AXUIElement?,
        pid: pid_t = 0,
        bundleID: String? = nil,
        appName: String = "—",
        caretLocation: Int = 0,
        prefix: String? = nil,
        nextChar: Character? = nil,
        report: (@Sendable (String) -> Void)? = nil,
        fallback: (@Sendable () -> Void)? = nil
    ) {
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.caretLocation = caretLocation
        self.prefix = prefix
        self.nextChar = nextChar
        self.report = report
        self.fallback = fallback
    }
}

/// A snapshot of the injector's current state for the debug diagnostics strip.
/// Pushed from the off-main coordinator to the MainActor diagnostics holder.
/// `prefixLength` is a *count only* — the prefix contents are never carried here.
nonisolated struct InjectionDebugInfo: Sendable, Equatable {
    var appName: String
    var mode: InjectionMode
    var neededManualAccessibility: Bool
    var prefixLength: Int
    var lastOp: String

    /// A copy with a new last-operation summary (the immutable session base stays
    /// intact while individual ops update only this field).
    func with(lastOp: String) -> InjectionDebugInfo {
        var copy = self
        copy.lastOp = lastOp
        return copy
    }
}

/// A text-insertion strategy. The `InjectionCoordinator` owns concrete strategies
/// and forwards to whichever one it chose for the session. Implementations live
/// **off the main actor** and serialize their own work on a private queue.
nonisolated protocol TextInjecting: Sendable {
    /// Begin a fresh session against the resolved context.
    func beginSession(context: InjectionContext)
    /// Render the full desired dictation text into the field.
    func render(_ target: String)
    /// Final authoritative render + end of session.
    func finalize(_ finalText: String)
}
