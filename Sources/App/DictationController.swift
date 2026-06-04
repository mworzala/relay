import AVFoundation
import Observation
import FluidAudio

/// The conductor: hold-to-talk hotkey → microphone capture → live LocalAgreement
/// transcription. In M6 it logs the confirmed/volatile hypotheses and the final
/// transcript; M7 adds the text injector + history, M8 adds the overlay pill.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable { case idle, arming, listening, finishing }
    private(set) var phase: Phase = .idle

    /// Live hypotheses (observable for the overlay / debugging).
    var confirmed: String { streaming.confirmed }
    var volatile: String { streaming.volatile }
    /// Input level passthrough for the waveform.
    var level: Float { mic.level }

    private let settings: AppSettings
    private let mic: MicrophoneCapture
    private let asr: ASREngine
    private let streaming = StreamingTranscriber()
    private let hotkey: HotkeyMonitor
    private let injector = TextInjector()

    /// Hold this long before a press actually starts dictation, so quick taps /
    /// Right-Command combos don't trigger a session.
    private let armDelayMs = 120

    private var armTask: Task<Void, Never>?

    /// Hooks for later milestones (injection, overlay). Set by the app wiring.
    @ObservationIgnored var onSessionStart: (() -> Void)?
    @ObservationIgnored var onHypothesis: (@MainActor (_ confirmed: String, _ volatile: String) -> Void)?
    @ObservationIgnored var onSessionFinish: (@MainActor (_ finalText: String) -> Void)?

    init(settings: AppSettings, mic: MicrophoneCapture, asr: ASREngine) {
        self.settings = settings
        self.mic = mic
        self.asr = asr
        self.hotkey = HotkeyMonitor(keybind: settings.keybind)
    }

    /// Start listening for the hotkey (call once after launch / permissions).
    func activate() {
        hotkey.setKeybind(settings.keybind)
        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.start()
    }

    func deactivate() {
        hotkey.stop()
        armTask?.cancel()
        if phase == .listening { Task { await finish() } }
    }

    /// Tear down and re-arm the hotkey monitors — used after the wizard grants
    /// Accessibility so the global monitor starts receiving events.
    func reactivate() {
        hotkey.stop()
        activate()
    }

    /// Re-read the keybind after the user changes it.
    func keybindChanged() { hotkey.setKeybind(settings.keybind) }

    // MARK: - Hotkey transitions

    private func handlePress() {
        guard phase == .idle else { return }
        guard asr.isReady, asr.asrManager != nil else {
            NSLog("Relay: hotkey pressed but model not ready (status not .ready)")
            return
        }
        phase = .arming
        armTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.armDelayMs ?? 120))
            guard let self, !Task.isCancelled, self.phase == .arming else { return }
            self.beginDictation()
        }
    }

    private func handleRelease() {
        armTask?.cancel()
        switch phase {
        case .arming:
            phase = .idle           // quick tap — never really started
        case .listening:
            Task { await finish() }
        case .idle, .finishing:
            break
        }
    }

    // MARK: - Session

    private func beginDictation() {
        guard let manager = asr.asrManager else { phase = .idle; return }
        phase = .listening
        injector.beginSession()

        streaming.onUpdate = { [weak self] confirmed, volatile in
            guard let self else { return }
            // Type the live hypothesis into the focused field (only the changed
            // tail is edited; see TextInjector / TextDiff).
            self.injector.render(Self.targetText(confirmed: confirmed, volatile: volatile))
            self.onHypothesis?(confirmed, volatile)
        }
        streaming.start(manager: manager)
        onSessionStart?()

        mic.beginCapture { [weak self] samples in
            // Capture queue: samples are already 16 kHz mono Float; hand to the loop.
            Task { @MainActor in self?.streaming.append(samples16k: samples) }
        }
    }

    private func finish() async {
        guard phase == .listening else { return }
        phase = .finishing
        mic.endCapture()

        // Authoritative full-buffer pass, then reconcile the on-screen text to it
        // (fixes any tail the streaming passes left wrong) and save to history.
        let finalText = await streaming.finish()
        injector.finalize(finalText)
        if !finalText.isEmpty {
            HistoryStore.add(finalText)
        }
        onSessionFinish?(finalText)
        phase = .idle
    }

    /// Build the full on-screen target from the committed prefix + volatile tail.
    private static func targetText(confirmed: String, volatile: String) -> String {
        [confirmed, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
