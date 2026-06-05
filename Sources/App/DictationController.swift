import AppKit
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
    /// Picks AX (primary) vs keystrokes (fallback) per session and applies prefix
    /// unification; owned by `AppModel` so its debug info can reach the overlay.
    private let injector: InjectionCoordinator

    /// Hold this long before a press actually starts dictation, so quick taps /
    /// Right-Command combos don't trigger a session.
    private let armDelayMs = 120

    private var armTask: Task<Void, Never>?

    /// Stats captured at session start (where the text lands and when it began),
    /// read back at `finish()`. The pill is a `NonActivatingPanel`, so the target
    /// app stays frontmost while the user holds to talk — capturing at *start* is
    /// the authoritative target, independent of the overlay's own timer.
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var sessionAppBundleID: String?
    @ObservationIgnored private var sessionAppName: String?

    /// Hooks for later milestones (injection, overlay). Set by the app wiring.
    @ObservationIgnored var onSessionStart: (() -> Void)?
    @ObservationIgnored var onHypothesis: (@MainActor (_ confirmed: String, _ volatile: String) -> Void)?
    @ObservationIgnored var onSessionFinish: (@MainActor (_ finalText: String) -> Void)?

    init(settings: AppSettings, mic: MicrophoneCapture, asr: ASREngine, injector: InjectionCoordinator) {
        self.settings = settings
        self.mic = mic
        self.asr = asr
        self.injector = injector
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
        switch phase {
        case .listening: Task { await finish() }
        case .arming: cancelArming()   // mic was warmed on key-down
        case .idle, .finishing: break
        }
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
        // Warm the mic and start buffering audio immediately on key-down, so the
        // hardware startup latency (~0.3–0.5s) overlaps the arm delay and the
        // opening words aren't clipped. If this turns out to be a quick tap we tear
        // it back down in handleRelease.
        streaming.prepare()
        mic.beginCapture { [weak self] samples in
            Task { @MainActor in self?.streaming.append(samples16k: samples) }
        }
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
            cancelArming()          // quick tap — never really started
        case .listening:
            Task { await finish() }
        case .idle, .finishing:
            break
        }
    }

    // MARK: - Session

    private func beginDictation() {
        guard let manager = asr.asrManager else { cancelArming(); return }
        phase = .listening

        // Capture the target app + start time before injection begins. The
        // frontmost app is where the dictation will land (the pill never steals
        // focus); the coordinator resolves the same app on its own queue.
        sessionStart = Date()
        let targetApp = NSWorkspace.shared.frontmostApplication
        sessionAppBundleID = targetApp?.bundleIdentifier
        sessionAppName = targetApp?.localizedName

        injector.beginSession()

        streaming.onUpdate = { [weak self] confirmed, volatile in
            guard let self else { return }
            // With "live unconfirmed text" on (default), inject confirmed + the
            // volatile tail — responsive, but the tail may rewrite/backspace as it
            // settles. Off injects only the committed prefix: it grows monotonically,
            // so the field appends smoothly and never backspace-storms (the tail
            // lands from the authoritative final pass on release).
            let target = self.settings.injectUnconfirmedText
                ? Self.joined(confirmed, volatile)
                : confirmed
            self.injector.render(target)
            self.onHypothesis?(confirmed, volatile)
        }
        // The mic has been capturing since key-down (handlePress) into the streaming
        // pre-roll; start now begins inference over that buffer + the live audio.
        streaming.start(manager: manager)
        onSessionStart?()
    }

    /// Tear down a session that armed (warmed the mic) but never started listening —
    /// a quick tap, a combo, or teardown during the arm window.
    private func cancelArming() {
        mic.endCapture()
        streaming.cancel()
        phase = .idle
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
            // Hold duration = start of dictation → now; the natural WPM denominator.
            let duration = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
            HistoryStore.add(
                finalText,
                appBundleID: sessionAppBundleID,
                appName: sessionAppName,
                durationSeconds: duration
            )
        }
        sessionStart = nil
        sessionAppBundleID = nil
        sessionAppName = nil
        onSessionFinish?(finalText)
        phase = .idle
    }

    /// Join the committed prefix and the volatile tail into the live target text.
    private static func joined(_ confirmed: String, _ volatile: String) -> String {
        [confirmed, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
