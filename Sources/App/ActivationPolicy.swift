import AppKit

/// The single place that decides Relay's *launch* Dock policy.
///
/// `.regular` = normal Dock app (default, per spec): launching shows the Dock icon,
/// menu bar, and config window. Once running, closing the config window drops the
/// app to `.accessory` (Dock-less, menu-bar-less, but still alive for the hotkey)
/// and reopening restores `.regular` — see AppDelegate.configWindowWillClose and
/// WindowReopener. Do NOT set `LSUIElement` in Info.plist; keep the decision here so
/// it can't drift between two sources of truth.
enum ActivationPolicy {
    static let current: NSApplication.ActivationPolicy = .regular

    static func apply() {
        NSApp.setActivationPolicy(current)
    }
}
