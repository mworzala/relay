import AppKit

/// The single place that decides whether Relay shows in the Dock.
///
/// `.regular` = normal Dock app (default, per spec). To make Relay a no-Dock
/// background/menu-less app later, change `current` to `.accessory` — that one
/// line is the entire switch. Do NOT also set `LSUIElement` in Info.plist; keep
/// the decision here so it can't drift between two sources of truth.
enum ActivationPolicy {
    static let current: NSApplication.ActivationPolicy = .regular

    static func apply() {
        NSApp.setActivationPolicy(current)
    }
}
