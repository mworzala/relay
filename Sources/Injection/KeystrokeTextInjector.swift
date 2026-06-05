import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Injects dictated text into whatever field has keyboard focus by posting
/// synthetic key events. This is the **fallback** strategy, used when the focused
/// field does not support Accessibility text editing (`AXTextInjector` is primary).
///
/// Serialized on a private queue so overlapping hypotheses can't interleave; it
/// remembers exactly what it has typed this session and only edits the diverging
/// tail (see `TextDiff`).
///
/// Posting uses `CGEvent` + `keyboardSetUnicodeString` (handles punctuation /
/// Unicode without per-key mapping) to `.cghidEventTap`; Backspaces are discrete
/// Delete (key code 51) down/up events.
///
/// `nonisolated` + `@unchecked Sendable`: this type lives off the main actor and
/// all mutable state is confined to `queue` (so it must NOT inherit the project's
/// MainActor-by-default isolation).
nonisolated final class KeystrokeTextInjector: TextInjecting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.relay.text-injector")
    private let source = CGEventSource(stateID: .hidSystemState)

    private static let deleteKey: CGKeyCode = 51   // Backspace/Delete

    // --- State, only touched on `queue` ---
    private var typed = ""
    private var sessionFocus: AXUIElement?
    private var report: (@Sendable (String) -> Void)?

    /// Begin a fresh dictation against a resolved context. The keystroke strategy
    /// only needs the focused element (to detect a mid-session focus change) and
    /// the optional debug reporter — it ignores the AX prefix/caret fields.
    func beginSession(context: InjectionContext) {
        queue.async {
            self.typed = ""
            self.sessionFocus = context.element ?? AXFocus.focusedElement()
            self.report = context.report
        }
    }

    /// Render `target` into the focused field by editing only the changed tail.
    func render(_ target: String) {
        queue.async { self.applyRender(target) }
    }

    /// Final reconcile + end of session (same mechanism; just the last render).
    func finalize(_ finalText: String) {
        queue.async {
            self.applyRender(finalText)
            self.sessionFocus = nil
            self.report = nil
        }
    }

    // MARK: - Implementation (on `queue`)

    /// Opt-in injector tracing: see `RelayDebug.injectTracing` (`RELAY_DEBUG=1` or
    /// the legacy `RELAY_DEBUG_INJECT=1`).
    private static let debugLogging = RelayDebug.injectTracing

    private func applyRender(_ target: String) {
        // Password fields enable Secure Input, which blocks synthetic keystrokes.
        // Fail gracefully rather than silently fighting the OS.
        if IsSecureEventInputEnabled() {
            if Self.debugLogging { NSLog("Relay/inject: secure input active — skipping") }
            report?("secure")
            typed = target   // keep our model consistent with intent
            return
        }

        var plan = TextDiff.plan(typed: typed, target: target)

        // Best-effort safety: if focus moved since the session started (user
        // clicked into a different field/app), don't backspace into it — just
        // commit the new text forward. AX text support is reliable in native Cocoa
        // fields but spotty in Electron/web inputs, so this is a safeguard, not a
        // guarantee.
        let focusMoved = plan.backspaces > 0 && focusChanged()
        if focusMoved {
            plan = TextDiff.Plan(backspaces: 0, insert: String(target.dropFirst(commonOnly(target))))
        }

        if Self.debugLogging {
            NSLog("Relay/inject typed=\(typed.count) target=\(target.count) backspaces=\(plan.backspaces) insert=\"\(String(plan.insert.prefix(30)))\" focusMoved=\(focusMoved)")
        }

        postBackspaces(plan.backspaces)
        postString(plan.insert)
        typed = target
        report?(focusMoved ? "focusMoved" : "typed \(plan.insert.count)")
    }

    /// Common-prefix length used when suppressing backspaces on a focus change.
    private func commonOnly(_ target: String) -> Int {
        TextDiff.commonPrefixCount(typed, target)
    }

    private func focusChanged() -> Bool {
        guard let sessionFocus else { return false }   // unknown → don't block
        guard let current = AXFocus.focusedElement() else { return false }
        return !CFEqual(current, sessionFocus)
    }

    private func postBackspaces(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            post(virtualKey: Self.deleteKey, keyDown: true)
            post(virtualKey: Self.deleteKey, keyDown: false)
        }
    }

    private func postString(_ string: String) {
        guard !string.isEmpty else { return }
        var utf16 = Array(string.utf16)
        let length = utf16.count
        // CRITICAL: the hold-to-talk key (e.g. Right Command) is physically held
        // during dictation. The .hidSystemState source makes events inherit that
        // live ⌘ flag — turning typed text into ⌘-shortcuts and Backspace into
        // ⌘+Delete. Clearing flags on every event makes injected keystrokes
        // literal. The unicode string is carried on BOTH key-down and key-up
        // (insertion happens once, on key-down; this matches the proven path).
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.flags = []
            down.keyboardSetUnicodeString(stringLength: length, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.flags = []
            up.keyboardSetUnicodeString(stringLength: length, unicodeString: &utf16)
            up.post(tap: .cghidEventTap)
        }
    }

    private func post(virtualKey: CGKeyCode, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else { return }
        // Clear inherited modifiers so Delete (51) is a plain Backspace, not the
        // ⌘+Delete (delete-to-line-start) that was wiping the user's text.
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
}
