import Foundation
import Observation

/// Composition root. Owns the long-lived app objects and wires their
/// dependencies in one place (SwiftUI `@State` properties can't reference each
/// other at init, so we build them here and inject the pieces into the
/// environment).
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let asr: ASREngine
    let mic: MicrophoneCapture
    let dictation: DictationController
    let overlay: OverlayController
    /// Caret-anchored live-transcript box for "Overlay + paste" mode.
    let transcriptOverlay: TranscriptOverlayController

    init() {
        let settings = AppSettings()
        let asr = ASREngine()
        let mic = MicrophoneCapture()
        let overlay = OverlayController()
        let transcriptOverlay = TranscriptOverlayController()

        self.settings = settings
        self.asr = asr
        self.mic = mic
        self.overlay = overlay
        self.transcriptOverlay = transcriptOverlay

        // Injection: AX-primary coordinator with keystroke fallback. Under
        // RELAY_DEBUG the coordinator publishes each session's decision/op to the
        // overlay diagnostics strip (off-main → hop to MainActor); otherwise no sink.
        let diagnostics = overlay.diagnostics
        let debugSink: (@Sendable (InjectionDebugInfo) -> Void)? = RelayDebug.overlayEnabled
            ? { @Sendable info in _ = Task { @MainActor in diagnostics.applyInjection(info) } }
            : nil
        let injector = InjectionCoordinator(debugSink: debugSink)
        let paste = PasteInjector()
        self.dictation = DictationController(
            settings: settings, mic: mic, asr: asr, injector: injector, paste: paste)

        mic.priorityProvider = { [settings] in settings.micPriority }

        // Wire the dictation lifecycle to the floating pill (shown in both modes).
        overlay.levelSource = { [mic] in mic.level }
        overlay.micNameSource = { [mic] in mic.activeDevice?.name }
        dictation.onSessionStart = { [overlay] in overlay.show() }
        dictation.onSessionFinish = { [overlay] _ in overlay.hide() }

        // Wire the "Overlay + paste" transcript box.
        dictation.onTranscriptBegin = { [transcriptOverlay] in transcriptOverlay.begin() }
        dictation.onTranscriptUpdate = { [transcriptOverlay] confirmed, volatile in
            transcriptOverlay.update(confirmed: confirmed, volatile: volatile)
        }
        dictation.onTranscriptEnd = { [transcriptOverlay] in transcriptOverlay.end() }
    }

    /// Bring the app fully online: device monitoring, hotkey, and (if the model is
    /// already downloaded) load it so hold-to-talk works immediately.
    func activate() async {
        // The unit-test bundle is hosted by this app, so launching for tests would
        // otherwise spin up the mic/model. Stay inert under XCTest.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        // Developer hook: visualize the overlay without a mic/model.
        if CommandLine.arguments.contains("--overlay-demo") {
            overlay.levelSource = { Float(0.5 + 0.5 * sin(Date().timeIntervalSinceReferenceDate * 7)) }
            overlay.show()
            return
        }

        mic.startMonitoring()
        dictation.activate()
        if ParakeetModel.isDownloaded() {
            await asr.prepare()
        }
    }
}
