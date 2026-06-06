import SwiftUI

/// The "Input Method" settings: an experimental toggle to route insertion through
/// Relay's bundled IME (better Electron/Chromium support), a mode picker
/// (always-on / just-in-time), and the install/setup state machine. Nothing is
/// installed or registered until the user taps **Set up**.
struct InputMethodSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(IMKController.self) private var imk

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Insert via input method", isOn: $settings.imkEnabled)
                    .onChange(of: settings.imkEnabled) { _, enabled in imk.setEnabled(enabled) }
                    .disabled(imk.isDictating)
            } header: {
                Text("Input Method — experimental")
            } footer: {
                Text("Routes dictation through a bundled macOS input method. It inserts reliably in Chromium/Electron apps (Slack, VS Code, Discord, Claude desktop, Notion) and shows a live underlined preview that self-corrects before it commits. Relay manages the input-method process itself and transparently falls back to the normal insertion path when it isn't available or in password fields.")
                    .font(.caption)
            }

            if settings.imkEnabled {
                Section {
                    Picker("Engagement", selection: $settings.imkEngagementMode) {
                        ForEach(IMKEngagementMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: settings.imkEngagementMode) { _, mode in imk.setMode(mode) }
                    .disabled(imk.isDictating)
                } footer: {
                    Text(settings.imkEngagementMode.detail).font(.caption)
                }

                Section {
                    setupRow
                } header: {
                    Text("Setup")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Input Method")
        .onAppear { imk.refreshState() }
    }

    @ViewBuilder private var setupRow: some View {
        switch imk.setupState {
        case .notInstalled:
            LabeledContent("Status") {
                Label("Not set up", systemImage: "circle.dashed").foregroundStyle(.secondary)
            }
            Button {
                imk.setUp()
            } label: {
                Label("Set up…", systemImage: "square.and.arrow.down")
            }
            Text("Installs Relay's input method. macOS requires you to activate it once — by logging out and back in, or by adding it under System Settings ▸ Keyboard ▸ Input Sources.")
                .font(.caption).foregroundStyle(.secondary)

        case .installing:
            LabeledContent("Status") {
                Label("Setting up…", systemImage: "gearshape.2").foregroundStyle(.blue)
            }

        case .needsActivation:
            LabeledContent("Status") {
                Label("Needs activation", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            Text("Installed, but macOS won't let an app enable a new input method on its own. Activate it once, either way:\n  • Open Keyboard settings → Input Sources → +, and add “Relay” (English), or\n  • Log out and back in once.\nRelay detects activation automatically — no need to come back here.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                imk.openKeyboardSettings()
            } label: {
                Label("Open Keyboard settings…", systemImage: "keyboard")
            }
            Button("Check again") { imk.recheck() }

        case .ready:
            LabeledContent("Status") {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if let bundle = imk.boundAppBundleID {
                LabeledContent("Active in") {
                    Text(bundle).foregroundStyle(.secondary).font(.callout)
                }
            }
            Button(role: .destructive) {
                imk.remove()
            } label: {
                Label("Remove input method", systemImage: "trash")
            }
            Text("Removing disables and deletes Relay's input method. A logout fully purges it from the input-source list.")
                .font(.caption).foregroundStyle(.secondary)

        case .failed(let reason):
            LabeledContent("Status") {
                Label("Setup failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).help(reason)
            }
            Text(reason).font(.caption).foregroundStyle(.red)
            Button("Try again") { imk.setUp() }
        }
    }
}
