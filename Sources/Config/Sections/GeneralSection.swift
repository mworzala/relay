import SwiftUI

/// General app settings: launch-at-login, dictation typing behavior, and a note
/// about background behavior.
struct GeneralSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Launch Relay at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLogin.setEnabled(enabled)
                    }
            } header: {
                Text("General")
            } footer: {
                Text("Relay has no menu bar item. Closing this window keeps it running in the background so the hold-to-talk key stays active; reopen the window from the Dock.")
                    .font(.caption)
            }

            Section {
                Toggle("Live unconfirmed text", isOn: $settings.injectUnconfirmedText)
                    .onChange(of: settings.injectUnconfirmedText) { _, _ in settings.save() }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Types low-confidence words as you speak and corrects them on the fly — more responsive, but the text may briefly rewrite (backspace). Turn off for smoother typing that only inserts words once they're settled, filling in the last word(s) when you release.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}
