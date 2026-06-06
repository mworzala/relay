import AppKit
import AVFoundation
import Carbon.HIToolbox
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
    /// Used by the `.typeDirectly` insertion mode.
    private let injector: InjectionCoordinator
    /// Clipboard + ⌘V finalize for the `.overlayPaste` insertion mode.
    private let paste: PasteInjector
    /// Optional input-method insertion path (plan 08). When enabled, installed, and a
    /// client binds, dictation streams through the IME (marked text + final commit);
    /// otherwise we fall through to the AX/paste path above.
    private let imk: IMKController

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
    /// Insertion mode resolved once at `beginDictation`, so toggling the setting
    /// mid-dictation can't reconfigure a live session.
    @ObservationIgnored private var sessionMode: InsertionMode = .typeDirectly
    /// Resolved once at `beginDictation`: true when the IME engaged and bound a
    /// client, so this session streams through IMK instead of `sessionMode`.
    @ObservationIgnored private var sessionUsesIMK = false
    /// Caret prefix + following char captured (off-main) at the start of an IMK
    /// session, so IMK text is unified against the existing field content (spacing /
    /// capitalization across the seam) exactly like the AX injector path. `nil` until
    /// the async capture lands — early marked renders insert verbatim, then unify.
    /// **Sensitive:** never log the prefix contents.
    @ObservationIgnored private var imkPrefix: String?
    @ObservationIgnored private var imkNextChar: Character?

    /// Hooks for later milestones (injection, overlay). Set by the app wiring.
    @ObservationIgnored var onSessionStart: (() -> Void)?
    @ObservationIgnored var onHypothesis: (@MainActor (_ confirmed: String, _ volatile: String) -> Void)?
    @ObservationIgnored var onSessionFinish: (@MainActor (_ finalText: String) -> Void)?
    /// Overlay-paste mode hooks (wired to `TranscriptOverlayController` by `AppModel`):
    /// show the caret-anchored transcript box, feed it the live hypothesis, hide it.
    @ObservationIgnored var onTranscriptBegin: (@MainActor () -> Void)?
    @ObservationIgnored var onTranscriptUpdate: (@MainActor (_ confirmed: String, _ volatile: String) -> Void)?
    @ObservationIgnored var onTranscriptEnd: (@MainActor () -> Void)?
    /// Debug-only: push an IMK diagnostics snapshot to the overlay strip (wired to
    /// `OverlayDiagnostics.applyIMK` by `AppModel`, only under `RelayDebug`). `nil`
    /// in normal runs, so building the snapshot is skipped entirely.
    @ObservationIgnored var onIMKDiagnostics: (@MainActor (IMKDebugInfo) -> Void)?

    init(settings: AppSettings, mic: MicrophoneCapture, asr: ASREngine,
         injector: InjectionCoordinator, paste: PasteInjector, imk: IMKController) {
        self.settings = settings
        self.mic = mic
        self.asr = asr
        self.injector = injector
        self.paste = paste
        self.imk = imk
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

    /// The microphone lost its device mid-dictation and couldn't reroute. New audio
    /// has stopped; the session rides out on the already-buffered audio and finalizes
    /// on release. Surface it so the dropout is at least diagnosable.
    func captureLost() {
        guard phase == .listening else { return }
        NSLog("Relay: microphone capture lost mid-dictation; finalizing on release from buffered audio")
    }

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

        // Snapshot the insertion mode once for this session (toggling mid-dictation
        // mustn't reconfigure a live session). Secure input, by contrast, is checked
        // *live* below — it can turn on mid-session as focus moves into a password
        // field, and we must never mirror a password into the overlay.
        sessionMode = settings.insertionMode

        // Premium path: if the IME is enabled/installed and a client binds, stream
        // through it (live underlined composition + a single authoritative commit on
        // release). Transparent fallback to the AX/paste path below when it can't
        // engage (not installed, no bound client, secure field). The engage may spin
        // the run loop briefly (the just-in-time focus-churn) — the overlay stays live.
        sessionUsesIMK = imk.beginDictationSession(
            targetPID: targetApp?.processIdentifier ?? 0,
            targetBundleID: targetApp?.bundleIdentifier ?? "")

        if sessionUsesIMK {
            // The IME does the inserting, but we reuse the AX prefix-capture so this
            // session unifies against whatever a previous one committed (a space and
            // capital after the prior sentence's period). The capture is async (the
            // Electron AX flip costs up to ~400ms); until it lands `imkPrefix` is nil
            // and renders insert verbatim — the authoritative final commit on release
            // unifies regardless, since the capture finishes well before then.
            imkPrefix = nil
            imkNextChar = nil
            injector.capturePrefix { [weak self] prefix, nextChar, _ in
                Task { @MainActor in
                    guard let self, self.sessionUsesIMK else { return }
                    self.imkPrefix = prefix
                    self.imkNextChar = nextChar
                    self.publishIMKDiagnostics(op: "prefix")
                }
            }
        } else {
            switch sessionMode {
            case .typeDirectly:
                injector.beginSession()
            case .overlayPaste:
                // Don't touch the field while streaming — the transcript lives in the
                // overlay and lands via paste on release.
                if !IsSecureEventInputEnabled() { onTranscriptBegin?() }
            }
        }

        streaming.onUpdate = { [weak self] confirmed, volatile in
            guard let self else { return }
            if self.sessionUsesIMK {
                // Re-check secure input every update: macOS suspends third-party IMEs
                // over password fields, but if focus moved into one mid-session, stop
                // rendering and cancel the composition rather than preview a password
                // through the IME (mirrors the overlay-paste and AX paths).
                if IsSecureEventInputEnabled() {
                    self.imk.cancelDictationSession()
                } else {
                    // Show the in-flight hypothesis as the live underlined composition
                    // in the field itself; honor "live unconfirmed text" (off → only the
                    // settled prefix is previewed). The final commit lands on release.
                    let preview = self.settings.injectUnconfirmedText
                        ? Self.joined(confirmed, volatile)
                        : confirmed
                    self.imk.renderMarked(self.unifyForIMK(preview))
                }
            } else {
                switch self.sessionMode {
                case .typeDirectly:
                    // With "live unconfirmed text" on (default), inject confirmed + the
                    // volatile tail — responsive, but the tail may rewrite/backspace as
                    // it settles. Off injects only the committed prefix: it grows
                    // monotonically, so the field appends smoothly and never
                    // backspace-storms (the tail lands from the final pass on release).
                    let target = self.settings.injectUnconfirmedText
                        ? Self.joined(confirmed, volatile)
                        : confirmed
                    self.injector.render(target)
                case .overlayPaste:
                    // Re-check secure input every update: if it turned on mid-session
                    // (focus moved into a password field), stop mirroring and hide the
                    // overlay rather than display the dictated password.
                    if IsSecureEventInputEnabled() {
                        self.onTranscriptEnd?()
                    } else {
                        self.onTranscriptUpdate?(confirmed, volatile)
                    }
                }
            }
            self.onHypothesis?(confirmed, volatile)
        }
        // The mic has been capturing since key-down (handlePress) into the streaming
        // pre-roll; start now begins inference over that buffer + the live audio.
        streaming.start(manager: manager)
        onSessionStart?()
        // Publish after `onSessionStart` (which calls overlay.show() → resets the
        // strip) so the IMK indicator sticks; the async prefix capture updates it.
        if sessionUsesIMK { publishIMKDiagnostics(op: "engaged") }
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
        if sessionUsesIMK {
            // Commit the authoritative final text through the IME (replaces the live
            // composition, ending it), then disengage (just-in-time restores the
            // user's source). Empty text clears the composition. Unify against the
            // captured prefix first so the committed sentence reads naturally after
            // the existing field content (the capture has long since completed).
            let unified = unifyForIMK(finalText)
            publishIMKDiagnostics(op: unified.isEmpty ? "clear" : "commit")
            let committed = imk.finishDictationSession(finalText: unified)
            if !committed && !unified.isEmpty {
                // The IME commit timed out / the helper was unresponsive, so the
                // authoritative text never landed. Don't lose the dictation — the JIT
                // source restore in finishDictationSession has put the user's normal
                // input back, so paste the final text at the caret (no-ops under
                // secure input and on empty text).
                NSLog("Relay: IMK commit failed; falling back to paste injection")
                publishIMKDiagnostics(op: "commit-fallback-paste")
                paste.paste(unified)
            }
        } else {
            switch sessionMode {
            case .typeDirectly:
                injector.finalize(finalText)
            case .overlayPaste:
                // Paste the final text at the user's real caret (the field was never
                // touched), then dismiss the overlay. PasteInjector no-ops under secure
                // input and on empty text.
                paste.paste(finalText)
                onTranscriptEnd?()
            }
        }
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

    /// Unify IMK text against the captured caret prefix (spacing / dedup /
    /// capitalization). Returns the text verbatim before the prefix capture lands
    /// (`imkPrefix == nil`), matching the AX path's no-prefix behavior.
    private func unifyForIMK(_ text: String) -> String {
        PrefixUnifier.unify(prefix: imkPrefix, dictation: text, nextChar: imkNextChar)
    }

    /// Push an IMK diagnostics snapshot to the overlay strip (no-op unless the debug
    /// hook is wired). The app name is the session's target; prefix length comes from
    /// the captured prefix (0 until the async capture lands).
    private func publishIMKDiagnostics(op: String) {
        guard let onIMKDiagnostics else { return }
        let engagement: String
        switch settings.imkEngagementMode {
        case .alwaysOn: engagement = "always-on"
        case .justInTime: engagement = "just-in-time"
        }
        onIMKDiagnostics(IMKDebugInfo(
            appName: sessionAppName ?? imk.boundAppBundleID ?? "—",
            engagement: engagement,
            prefixLength: imkPrefix?.utf16.count ?? 0,
            lastOp: op))
    }

    /// Join the committed prefix and the volatile tail into the live target text.
    private static func joined(_ confirmed: String, _ volatile: String) -> String {
        [confirmed, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
