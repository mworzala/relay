import AppKit

/// Thin AppKit delegate for the lifecycle behaviors SwiftUI can't express:
/// keep running after the window closes, and re-show the window on reopen.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the (isolated) launch Dock/activation choice. Default = normal Dock app.
        ActivationPolicy.apply()

        // Closing the config window drops Relay to a Dock-less, menu-bar-less
        // accessory app (see configWindowWillClose) — but it keeps running for the
        // global hotkey. Reopening restores the regular policy + window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil)
    }

    /// When the configuration window closes, hide Relay from the Dock and the menu
    /// bar by switching to the accessory activation policy. The process stays alive
    /// (so hold-to-talk keeps working); reopening from the Dock/Spotlight/Applications
    /// restores the regular policy and the window (see applicationShouldHandleReopen →
    /// WindowReopener). Filtered to the config window so the dictation overlay panels
    /// closing don't trigger it. Deferred to the next runloop so the close completes
    /// cleanly before the policy flips.
    @objc private func configWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == RelayWindowID.config.rawValue else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// On quit, restore the user's previous input source and stop the IME helper, so
    /// an always-on IME doesn't linger as the active source after Relay is gone.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared?.imk.shutdown()
    }

    /// Keep Relay alive in the background after the config window is closed so the
    /// global hold-to-talk hotkey stays active. The window's close instead drops the
    /// app to an accessory (Dock-less, menu-bar-less) policy; see configWindowWillClose.
    /// The app is reached again by relaunching it (Spotlight/Applications/Dock recents),
    /// which routes to applicationShouldHandleReopen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-show the configuration window when the user relaunches Relay (Spotlight, the
    /// Applications folder, or the Dock) with no visible windows. Since the app is
    /// already running as an accessory, the launch arrives here as a reopen event;
    /// WindowReopener restores the regular Dock policy and surfaces the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WindowReopener.shared.reopenConfigWindow()
        }
        return true
    }
}
