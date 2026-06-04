import SwiftUI

/// Full-window takeover shown on first run (gated by `AppSettings.firstRunComplete`).
/// Dims the config window and centers the wizard card, like Apple's setup flows.
struct OnboardingCover: View {
    var onFinish: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.28))
                .ignoresSafeArea()
            OnboardingView(onFinish: onFinish)
                .shadow(radius: 30, y: 12)
        }
        .transition(.opacity)
    }
}

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ASREngine.self) private var asr

    var onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var permissions = PermissionsModel()

    enum Step: Int, CaseIterable { case welcome, model, permissions, done }

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step.rawValue, total: Step.allCases.count)
                .padding(.top, 22)
                .padding(.bottom, 16)

            Divider()

            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .model: ModelStep()
                case .permissions: PermissionsStep(permissions: permissions)
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

            Divider()

            HStack {
                if step != .welcome && step != .done {
                    Button("Back") { back() }
                }
                Spacer()
                Button(primaryTitle) { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .padding(20)
        }
        .frame(width: 580, height: 480)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .onAppear { permissions.refresh() }
    }

    private var primaryTitle: String {
        switch step {
        case .done: return "Get Started"
        default: return "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .model: return asr.isReady
        case .permissions: return permissions.mic == .granted && permissions.accessibilityTrusted
        case .done: return true
        }
    }

    private func advance() {
        switch step {
        case .done:
            permissions.stopPolling()
            settings.firstRunComplete = true
            settings.save()
            onFinish()
        default:
            let nextRaw = step.rawValue + 1
            if let next = Step(rawValue: nextRaw) {
                step = next
                onEnter(next)
            }
        }
    }

    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    private func onEnter(_ step: Step) {
        switch step {
        case .model:
            if !asr.isReady { Task { await asr.prepare() } }
        case .permissions:
            permissions.refresh()
            permissions.startPolling()
        default:
            break
        }
    }
}

// MARK: - Step indicator

private struct StepIndicator: View {
    let current: Int
    let total: Int
    private let titles = ["Welcome", "Model", "Permissions", "Done"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<total, id: \.self) { index in
                HStack(spacing: 6) {
                    Circle()
                        .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 9, height: 9)
                    if index < titles.count {
                        Text(titles[index])
                            .font(.caption)
                            .foregroundStyle(index == current ? .primary : .secondary)
                    }
                }
                if index < total - 1 {
                    Rectangle().fill(.secondary.opacity(0.25)).frame(width: 18, height: 1)
                }
            }
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("Welcome to Relay")
                .font(.largeTitle.weight(.semibold))
            Text("Hold your dictation key, speak, and Relay types what you say into any app — on-device, using Parakeet on the Apple Neural Engine.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
    }
}

private struct ModelStep: View {
    @Environment(ASREngine.self) private var asr

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("Download the speech model")
                .font(.title2.weight(.semibold))
            Text("Parakeet v3 (~600 MB) downloads once into your Application Support folder and runs entirely on-device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            statusView
                .frame(maxWidth: 420)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch asr.status {
        case .notDownloaded:
            Button("Download Parakeet v3") { Task { await asr.prepare() } }
                .controlSize(.large)
        case .downloading(let fraction):
            VStack(spacing: 6) {
                ProgressView(value: fraction)
                Text("Downloading… \(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .loading:
            VStack(spacing: 6) {
                ProgressView()
                Text("Compiling for the Neural Engine (one-time, ~30s)…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Retry") { Task { await asr.retry() } }
            }
        }
    }
}

private struct PermissionsStep: View {
    @Bindable var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Grant permissions")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            permissionRow(
                title: "Microphone",
                detail: "To hear what you say while you hold your dictation key.",
                granted: permissions.mic == .granted,
                denied: permissions.mic == .denied
            ) {
                Button("Allow") { Task { await permissions.requestMicrophone() } }
            }

            permissionRow(
                title: "Accessibility",
                detail: "To type the transcribed text into the focused field (and to detect the global hold-to-talk key). Relay adds itself to the list automatically.",
                granted: permissions.accessibilityTrusted,
                denied: false
            ) {
                HStack {
                    Button("Allow") { permissions.requestAccessibility() }
                    Button("Open Settings") { permissions.openAccessibilitySettings() }
                        .buttonStyle(.link)
                }
            }

            Spacer()
        }
        .onAppear { permissions.refresh() }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        denied: Bool,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : (denied ? "xmark.circle.fill" : "circle"))
                .font(.title2)
                .foregroundStyle(granted ? .green : (denied ? .red : .secondary))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { action() }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.largeTitle.weight(.semibold))
            Text("Hold your dictation key (Right Command by default) anywhere and start speaking. You can change the key and microphone priority in the configuration window.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
        }
    }
}
