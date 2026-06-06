import AppKit

/// Pure, testable decoder that turns raw key events into press/release
/// transitions for the configured `Keybind`. Kept free of `NSEvent` *monitors*
/// (just `NSEvent.ModifierFlags`/key codes) so it can be unit-tested with
/// synthetic input.
///
/// Bare-modifier binds (the default Right Command) are detected on `.flagsChanged`
/// by **toggling** per key code: each physical press and release of a modifier
/// emits exactly one `.flagsChanged` for that key code, so toggling reliably
/// distinguishes down vs up even when the same device-independent flag (e.g.
/// `.command`) is also held by the other side (Left vs Right).
nonisolated struct HotkeyMatcher {
    enum Transition { case press, release }

    var keybind: Keybind
    private var bareKeyIsDown = false

    init(keybind: Keybind) { self.keybind = keybind }

    /// Re-arm when the bind changes (avoids a stale toggle state).
    mutating func reset() { bareKeyIsDown = false }

    mutating func handleFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Transition? {
        guard keybind.isBareModifier, keyCode == keybind.keyCode else { return nil }
        let wasDown = bareKeyIsDown
        if let bit = keybind.bareModifierFlag, flags.intersection(bit).isEmpty {
            // The bound modifier's flag is gone → the key is definitively UP, whatever
            // a (possibly desynced) toggle thought. This self-corrects a missed event:
            // a release that arrives while we think we're already up emits no spurious
            // press. The flag is absent only when no side holds the modifier.
            bareKeyIsDown = false
        } else {
            // Flag still present (the other Left/Right side may hold the same
            // device-independent flag) or an unknown key → toggle, as before.
            bareKeyIsDown.toggle()
        }
        guard bareKeyIsDown != wasDown else { return nil }   // no real transition
        return bareKeyIsDown ? .press : .release
    }

    mutating func handleKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Transition? {
        guard !keybind.isBareModifier, keyCode == keybind.keyCode else { return nil }
        // All required modifiers present?
        guard flags.intersection(.relevant) == keybind.modifierFlags.intersection(.relevant) else {
            return nil
        }
        return .press
    }

    mutating func handleKeyUp(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Transition? {
        guard !keybind.isBareModifier, keyCode == keybind.keyCode else { return nil }
        return .release
    }
}

extension NSEvent.ModifierFlags {
    /// The modifier bits we consider for combo matching (ignore caps lock, fn, etc.).
    nonisolated static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
}
