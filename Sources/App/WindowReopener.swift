import AppKit
import SwiftUI

/// Bridges the AppKit reopen event to SwiftUI's window system. SwiftUI's single
/// `Window` scene does not automatically re-open after being closed, so we keep a
/// reference to the SwiftUI `openWindow` action and invoke it on Dock reopen.
@MainActor
final class WindowReopener {
    static let shared = WindowReopener()

    /// Set from the SwiftUI side once the scene environment is available.
    var openWindow: ((String) -> Void)?

    private init() {}

    func reopenConfigWindow() {
        NSApp.activate(ignoringOtherApps: true)

        // If the config window already exists (e.g. just hidden), bring it forward.
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == RelayWindowID.config.rawValue }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Otherwise ask SwiftUI to create it again.
        openWindow?(RelayWindowID.config.rawValue)
    }
}
