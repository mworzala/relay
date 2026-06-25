import SwiftUI

/// Click-to-record keybind control. Shows the current hold-to-talk binding and,
/// on click, captures the next key/modifier and persists it (updating the live
/// hotkey monitor).
struct KeybindSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var dictation
    @State private var recorder = KeybindRecorder()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Hold-to-talk") {
                    Button(action: toggleRecording) {
                        Text(recorder.isRecording ? "Press a key…" : settings.keybind.displayString)
                            .font(.body.monospaced())
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.bordered)
                    .tint(recorder.isRecording ? .accentColor : nil)
                }
                if recorder.isRecording {
                    Text("Press a key or a bare modifier (Esc to cancel). For hold-to-talk, a bare modifier like Right Command works best.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Press and hold this key to dictate; release to finalize. The observer is fully passive — your keyboard behaves normally when you're not dictating, and modifier combos still reach other apps.")
                    .font(.caption)
            }

            Section {
                Toggle("Double-tap to lock", isOn: $settings.enableDoubleTapLock)
                    .onChange(of: settings.enableDoubleTapLock) { _, _ in settings.save() }
            } footer: {
                Text("Quickly double-tap the shortcut to start a hands-free session: it keeps listening after you let go and only stops when you tap the shortcut again. A lock appears on the pill while it's active. A single hold still works as usual.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcut")
        .onDisappear { recorder.stop() }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            recorder.onCapture = { keybind in
                settings.keybind = keybind
                settings.save()
                dictation.keybindChanged()
            }
            recorder.start()
        }
    }
}
