import AppKit

/// The hold-to-talk binding. Persisted in settings.json.
///
/// `keyCode` is the hardware virtual key code (e.g. 54 = Right Command). For a
/// "bare modifier" bind (`isBareModifier == true`) the key IS a modifier and
/// `modifiers` is empty; for a regular combo, `modifiers` holds the accompanying
/// modifier flags (raw value of `NSEvent.ModifierFlags`) and `keyCode` is the
/// non-modifier key.
struct Keybind: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt
    var isBareModifier: Bool

    /// Default per spec: press-and-hold **Right Command**.
    static let rightCommand = Keybind(keyCode: 54, modifiers: 0, isBareModifier: true)

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Human-readable label for the keybind UI.
    var displayString: String {
        if isBareModifier {
            return Self.bareModifierName(for: keyCode)
        }
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s.isEmpty ? "—" : s
    }

    /// Names for the bare modifier keys we can bind (Right/Left of each).
    static func bareModifierName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 63: return "fn"
        default: return "Modifier (key \(keyCode))"
        }
    }

    /// Minimal key-code → label map; expanded as the recorder grows (M6).
    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 53: return "Esc"
        case 48: return "Tab"
        default: return "Key \(keyCode)"
        }
    }
}
