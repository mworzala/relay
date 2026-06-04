import SwiftUI

/// Root of the configuration window. Hosts the sectioned config UI, the first-run
/// wizard (a takeover cover until `firstRunComplete`), and registers SwiftUI's
/// `openWindow` action for AppKit-driven reopen.
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var dictation

    var body: some View {
        ConfigView()
            .overlay {
                if !settings.firstRunComplete {
                    OnboardingCover {
                        // Wizard finished: refresh the hotkey monitors now that
                        // Accessibility may have just been granted.
                        dictation.reactivate()
                    }
                }
            }
            .animation(.smooth(duration: 0.25), value: settings.firstRunComplete)
            .modifier(WindowReopenerBridge())
    }
}

/// Captures SwiftUI's `openWindow` action so `WindowReopener` (driven by the
/// AppKit reopen event) can re-create the config window after it is closed.
private struct WindowReopenerBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            WindowReopener.shared.openWindow = { id in
                openWindow(id: id)
            }
        }
    }
}
