import SwiftUI

/// Live model status: not downloaded / downloading(%) / loading / ready / error,
/// with a download/retry action. Backed by `ASREngine`.
struct ModelStatusSection: View {
    @Environment(ASREngine.self) private var asr

    var body: some View {
        Form {
            Section {
                LabeledContent("Speech model") {
                    Text("Parakeet v3 (parakeet-tdt-0.6b-v3)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") { statusView }
                if case .downloading(let fraction) = asr.status {
                    ProgressView(value: fraction) {
                        Text("Downloading model…")
                    } currentValueLabel: {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Parakeet v3 runs on the Apple Neural Engine. It is stored under ~/Library/Application Support/Relay/Models/ and downloaded on first use (a few hundred MB).")
                    .font(.caption)
            }

            Section {
                Button(action: { Task { await asr.retry() } }) {
                    Label(actionTitle, systemImage: actionSymbol)
                }
                .disabled(isBusy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Model")
    }

    @ViewBuilder private var statusView: some View {
        switch asr.status {
        case .notDownloaded:
            Label("Not downloaded", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .downloading:
            Label("Downloading…", systemImage: "arrow.down.circle.dotted").foregroundStyle(.blue)
        case .loading:
            Label("Loading…", systemImage: "gearshape.2").foregroundStyle(.blue)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private var isBusy: Bool {
        switch asr.status {
        case .downloading, .loading: return true
        default: return false
        }
    }

    private var actionTitle: String {
        switch asr.status {
        case .notDownloaded: return "Download & Load"
        case .downloading, .loading: return "Working…"
        case .ready: return "Reload"
        case .error: return "Retry"
        }
    }

    private var actionSymbol: String {
        switch asr.status {
        case .ready: return "arrow.clockwise"
        case .error: return "arrow.clockwise"
        default: return "arrow.down.circle"
        }
    }
}
