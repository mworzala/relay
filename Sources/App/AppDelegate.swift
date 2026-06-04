import AppKit

/// Thin AppKit delegate for the lifecycle behaviors SwiftUI can't express:
/// keep running after the window closes, and re-show the window on reopen.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the (isolated) Dock/activation choice. Default = normal Dock app.
        ActivationPolicy.apply()
    }

    /// Keep Relay alive in the background after the config window is closed so the
    /// global hold-to-talk hotkey stays active. There is intentionally no menu bar
    /// item; the app is reached again via the Dock (reopen) or relaunch.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-show the configuration window when the user clicks the Dock icon (or
    /// relaunches) with no visible windows. Wired to SwiftUI's openWindow via
    /// WindowReopener in milestone 10; for now activation is enough to surface any
    /// existing window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WindowReopener.shared.reopenConfigWindow()
        }
        return true
    }
}
