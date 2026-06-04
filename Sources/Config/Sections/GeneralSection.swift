import SwiftUI

/// General app settings: launch-at-login and a note about background behavior.
struct GeneralSection: View {
    @State private var launchAtLogin = false

    var body: some View {
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
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}
