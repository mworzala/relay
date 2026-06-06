import AppKit
import Carbon

/// Selects Relay's IME as the current input source and restores the previous one.
/// All TIS source management lives here (main-actor by the project default); the
/// AppKit focus-churn that *engages* a just-in-time selection lives in the helper
/// (`FocusChurn`), driven over IPC.
///
/// `TISSelectInputSource` updates the global current-source record (and the
/// menu-bar/HUD); for always-on it's enough (the user's own next focus change binds
/// the IME), and for just-in-time the helper's focus-churn forces the rebind.
/// Restoring the previous source needs **no** churn — it's free, no second flash.
enum IMKSwitcher {
    /// The currently-selected keyboard input source (to capture before selecting
    /// ours, so it can be restored later).
    static func currentSource() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    /// Is Relay's IME the current source right now?
    static func isOursCurrent() -> Bool {
        guard let current = currentSource() else { return false }
        return IMKInstaller.stringProp(current, kTISPropertyInputSourceID) == IMKMessaging.inputSourceID
    }

    /// Select Relay's IME (enabling it first if needed). Returns false if our
    /// selectable mode isn't available (not installed / needs logout).
    @discardableResult
    static func selectOurs() -> Bool {
        guard let src = IMKInstaller.selectableSource() else { return false }
        if !IMKInstaller.boolProp(src, kTISPropertyInputSourceIsEnabled) {
            TISEnableInputSource(src)
        }
        let status = TISSelectInputSource(src)
        NSLog("Relay/imk: TISSelectInputSource(ours) → \(status)")
        return status == noErr
    }

    /// Restore a previously-captured source (free — no focus-churn).
    static func restore(_ source: TISInputSource?) {
        guard let source else { return }
        let status = TISSelectInputSource(source)
        NSLog("Relay/imk: TISSelectInputSource(previous) → \(status)")
    }
}
