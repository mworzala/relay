import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp` (macOS 13+). The service status is
/// the source of truth; we don't persist a duplicate flag.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Relay: failed to set launch-at-login=\(enabled): \(error)")
        }
    }
}
