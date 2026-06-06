import SwiftUI

/// Identifiers for the app's windows. Using a stable id lets us re-open the
/// single configuration window on Dock click / relaunch.
enum RelayWindowID: String {
    case config = "relay.config"
}

@main
struct RelayApp: App {
    /// AppKit lifecycle hooks (background running, reopen handling) that SwiftUI
    /// alone does not expose. Kept thin — see App/AppDelegate.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Composition root: settings, model engine, microphone, dictation conductor.
    @State private var model = AppModel()

    var body: some Scene {
        // A single (non-group) window: the configuration window. It is the app's
        // only normal window; closing it does NOT quit the app (see AppDelegate).
        Window("Relay", id: RelayWindowID.config.rawValue) {
            RootView()
                .environment(model.settings)
                .environment(model.asr)
                .environment(model.mic)
                .environment(model.dictation)
                .environment(model.imk)
                .task { await model.activate() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 560)
        .modelContainer(HistoryStore.container)
    }
}
