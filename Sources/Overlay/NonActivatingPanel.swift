import AppKit

/// A panel that can float above everything (including full-screen apps) but never
/// becomes key or main — so the user's text field keeps keyboard focus and
/// injected keystrokes land there, not in the pill.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
