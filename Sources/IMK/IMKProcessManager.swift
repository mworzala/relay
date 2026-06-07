import AppKit

/// Relay owns the helper process lifecycle (plan §1b). It launches the **installed**
/// copy (the same bundle TSM knows) so the helper is alive to receive IPC — required
/// for just-in-time mode, where the IME isn't the selected source between dictations
/// and TSM wouldn't otherwise keep it running. The CFMessagePort singleton guard in
/// the helper means a Relay-launched instance and any TSM-spawned one don't fight:
/// whichever binds the port first wins; the other exits.
enum IMKProcessManager {
    static func isRunning() -> Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: IMKMessaging.helperBundleID)
            .isEmpty
    }

    /// Launch the installed helper (no activation, no Recents). No-op if not
    /// installed or already running.
    static func ensureRunning() {
        guard IMKInstaller.isInstalled(), !isRunning() else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        let url = IMKInstaller.installURL
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                NSLog("Relay/imk: launched helper")
            } catch {
                NSLog("Relay/imk: helper launch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Terminate any running helper instance(s) (feature disabled / app quitting).
    ///
    /// Graceful first, then force-kill any survivor. During app quit there's little
    /// time for the AppleEvent `terminate()` to land before Relay exits, so a plain
    /// graceful request alone would let the helper outlive the app (a stranded
    /// IMKServer keeps the input source alive and can be re-bound). We give it a
    /// bounded moment — spinning the run loop rather than sleeping so the main thread
    /// stays responsive during termination — then `forceTerminate` anything left.
    static func terminate() {
        func running() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: IMKMessaging.helperBundleID)
        }
        let initial = running()
        guard !initial.isEmpty else { return }
        for app in initial { app.terminate() }

        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline, !running().isEmpty {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        for app in running() { app.forceTerminate() }
    }
}
