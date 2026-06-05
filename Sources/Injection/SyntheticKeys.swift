import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts synthetic key chords via `CGEvent` — used to repair the caret after a
/// Chromium value-write (which collapses the contenteditable selection to 0).
/// Chromium ignores AX selection writes on contenteditable but DOES honor real
/// keyboard input, so a keystroke is the reliable way to move the caret.
///
/// `nonisolated`: called from the injector's off-main queue.
nonisolated enum SyntheticKeys {
    // Immutable after creation; CGEvent posting is thread-safe.
    nonisolated(unsafe) private static let source = CGEventSource(stateID: .hidSystemState)

    /// A fixed magic constant stamped into the `eventSourceUserData` field of every
    /// synthetic CGEvent Relay posts, so input observers can recognize Relay's own
    /// events (its ⌘V / caret-repair keystrokes) and decline to react to them.
    /// **Best-effort:** some event paths drop user-data fields, so this is a guard
    /// only — never rely on it for correctness. ('RLY' + 0x01.)
    static let sentinel: Int64 = 0x52_4C_59_01

    /// Whether `event` carries Relay's self-event sentinel.
    static func isRelaySynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == sentinel
    }

    /// Post a key down+up with explicit modifier flags. Flags are set explicitly
    /// (never inherited), so a still-held hold-to-talk modifier can't leak in —
    /// though caret repair runs at finalize, after the key is released. Both events
    /// are stamped with `sentinel` so Relay can ignore its own keystrokes.
    static func post(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: sentinel)
        up.setIntegerValueField(.eventSourceUserData, value: sentinel)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Move the caret to the very end of the focused editable field: ⌘A (select
    /// all) then → (collapse the selection to its right/end). Reliable across single
    /// and multi-line editables.
    static func moveCaretToEnd() {
        post(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        post(CGKeyCode(kVK_RightArrow))
    }

    /// Move the caret left by `count` presses of the Left arrow (no modifiers). Used
    /// to back the caret up from the field end to the end of a *mid-field* insertion,
    /// after `moveCaretToEnd` over-shoots past the preserved trailing text. `count` is
    /// a UTF-16 unit count (≈ one arrow press per unit for ordinary text).
    static func moveLeft(by count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count { post(CGKeyCode(kVK_LeftArrow)) }
    }

    /// Paste the current clipboard contents at the caret: ⌘V. Routes through the
    /// app's native edit pipeline, so the caret lands after the inserted text and a
    /// single undo reverts it — the basis of "Overlay + paste" insertion. The flag
    /// is set explicitly so a still-held hold-to-talk modifier can't leak in.
    static func paste() {
        post(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }
}
