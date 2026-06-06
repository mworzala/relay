import AppKit
import ApplicationServices
import Carbon
import Observation

/// The main app's IMK orchestrator. Owns the installer, switcher, process manager,
/// IPC client, and the swappable engagement strategy; drives both the settings UI
/// (install state + actions) and the dictation insertion path.
///
/// `@MainActor @Observable`: it's UI state and all TIS calls are main-thread-only.
/// Nothing here runs unless the user explicitly turns the feature on.
@MainActor
@Observable
final class IMKController {
    /// Where setup stands, for the settings row's state machine.
    enum SetupState: Equatable {
        case notInstalled
        case installing
        /// Installed and registered, but not yet *enabled* — a freshly-registered
        /// third-party IME can't be enabled until the user logs out/in once or adds
        /// it in System Settings (gotcha §3.4). We poll and flip to `.ready` then.
        case needsActivation
        /// Installed, registered, AND enabled (the authoritative ready signal).
        case ready
        case failed(String)
    }

    private(set) var setupState: SetupState = .notInstalled
    /// The app the IME is currently bound to (engaged), for display only. Driven by
    /// helper events; the per-dictation begin reply is the authoritative check.
    private(set) var boundAppBundleID: String?

    private let settings: AppSettings
    private let ipc = IMKMessagePortClient()
    private let memory = IMKSourceMemory()
    private var strategy: IMKEngagement
    /// Polls `isEnabled()` while we're waiting for the user to activate the source
    /// (logout/login or System Settings add), then flips to `.ready`.
    @ObservationIgnored private var activationPoll: Timer?

    /// True while a dictation is routed through IMK (between begin/end), so renders
    /// after a failed engage are dropped rather than sent to an unbound helper.
    private var sessionActive = false
    /// Set when enable/mode is changed mid-dictation; the change is applied when the
    /// session ends so a live composition / source switch isn't torn down underneath it.
    private var pendingReengage = false

    /// Whether a dictation is currently routed through IMK (for UI gating).
    var isDictating: Bool { sessionActive }

    init(settings: AppSettings) {
        self.settings = settings
        self.strategy = Self.makeStrategy(settings.imkEngagementMode)
        refreshState()
    }

    private static func makeStrategy(_ mode: IMKEngagementMode) -> IMKEngagement {
        switch mode {
        case .alwaysOn: return AlwaysOnEngagement()
        case .justInTime: return JustInTimeEngagement()
        }
    }

    // MARK: - Lifecycle (app start / quit)

    /// Bring IMK online if the user left it enabled. Called once after launch.
    func start() {
        refreshState()
        reconcileEngagement()
    }

    /// Tear down on app quit: restore the user's source and stop the helper.
    func shutdown() {
        stopPollingForActivation()
        guard settings.imkEnabled else { return }
        strategy.deactivate(memory: memory)
        ipc.stop()
        IMKProcessManager.terminate()
    }

    private func beginListening() {
        ipc.startEventListener { @Sendable [weak self] event, payload in
            Task { @MainActor in self?.handle(event: event, payload: payload) }
        }
    }

    private func handle(event: IMKMessaging.Event, payload: String) {
        switch event {
        case .engaged: boundAppBundleID = payload.isEmpty ? nil : payload
        case .disengaged: boundAppBundleID = nil
        }
    }

    // MARK: - Setup flow (settings UI)

    /// Recompute setup state. `.ready` requires the source to be actually **enabled**
    /// — being merely installed/registered/select-capable is not enough (a fresh
    /// registration is select-capable but disabled until logout/login). Preserves a
    /// transient `.installing`/`.failed` so a poll tick doesn't clobber it.
    func refreshState() {
        if case .installing = setupState { return }
        if case .failed = setupState { return }
        if !IMKInstaller.isInstalled() {
            setupState = .notInstalled
        } else if IMKInstaller.isEnabled() {
            setupState = .ready
        } else {
            setupState = .needsActivation
        }
    }

    /// Re-check after the user logs out/in or adds the source in System Settings (the
    /// "Check again" affordance): relaunch the helper so it self-activates, and either
    /// engage (if now enabled) or keep polling.
    func recheck() {
        refreshState()
        IMKProcessManager.ensureRunning()
        if setupState == .ready {
            if settings.imkEnabled { reconcileEngagement() }
        } else if case .needsActivation = setupState {
            beginPollingForActivation()
        }
    }

    /// Install + register the bundled IME and launch the helper (which self-activates
    /// from its own process). Because a fresh third-party IME can't be enabled until a
    /// logout/login or a manual System Settings add, this usually lands in
    /// `.needsActivation`; we poll and flip to `.ready` once the user activates it.
    func setUp() {
        guard IMKInstaller.embeddedAppURL != nil else {
            setupState = .failed("This build has no embedded input method.")
            return
        }
        setupState = .installing
        switch IMKInstaller.install() {
        case .ok:
            IMKProcessManager.ensureRunning()
            // Re-evaluate off the transient .installing state.
            setupState = IMKInstaller.isEnabled() ? .ready : .needsActivation
            if setupState == .ready {
                if settings.imkEnabled { reconcileEngagement() }
            } else {
                beginPollingForActivation()
            }
        case .failed(let reason):
            setupState = .failed(reason)
        }
    }

    /// Open System Settings ▸ Keyboard so the user can add Relay under Input Sources.
    func openKeyboardSettings() { IMKInstaller.openKeyboardSettings() }

    // MARK: - Activation polling (waiting for logout/login or a System Settings add)

    private func beginPollingForActivation() {
        stopPollingForActivation()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard IMKInstaller.isEnabled() else { return }
                self.stopPollingForActivation()
                self.setupState = .ready
                if self.settings.imkEnabled { self.reconcileEngagement() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        activationPoll = timer
    }

    private func stopPollingForActivation() {
        activationPoll?.invalidate()
        activationPoll = nil
    }

    /// Remove the IME entirely: restore the user's source, disable, delete the
    /// bundle, stop the helper, and turn the feature off.
    func remove() {
        stopPollingForActivation()
        if IMKSwitcher.isOursCurrent() { IMKSwitcher.restore(memory.previous) }
        memory.previous = nil
        ipc.stop()
        IMKProcessManager.terminate()
        IMKInstaller.uninstall()
        settings.imkEnabled = false
        settings.save()
        boundAppBundleID = nil
        refreshState()
    }

    // MARK: - Enable / disable / mode change (settings UI)

    func setEnabled(_ enabled: Bool) {
        settings.imkEnabled = enabled
        settings.save()
        // Defer mid-dictation changes so we don't tear down a live session.
        guard !sessionActive else { pendingReengage = true; return }
        reconcileEngagement()
    }

    /// Changing the mode re-engages: tear down the old strategy, swap, engage the new
    /// one (always-on selects now; just-in-time restores + switches per dictation).
    func setMode(_ mode: IMKEngagementMode) {
        settings.imkEngagementMode = mode
        settings.save()
        guard !sessionActive else { pendingReengage = true; return }
        reconcileEngagement()
    }

    /// Bring engagement in line with the current settings (enabled? which mode? is the
    /// source actually enabled yet?). Tears down whatever the current strategy had
    /// engaged first. Idempotent.
    private func reconcileEngagement() {
        strategy.deactivate(memory: memory)
        strategy = Self.makeStrategy(settings.imkEngagementMode)
        guard settings.imkEnabled else { teardownEngagement(); return }
        switch setupState {
        case .ready:
            stopPollingForActivation()
            enableEngagement()
        case .needsActivation:
            // Enabled but not yet activated by the user — keep the helper alive (it
            // self-activates) and poll so we engage the moment it becomes enabled.
            IMKProcessManager.ensureRunning()
            beginPollingForActivation()
        case .notInstalled, .installing, .failed:
            teardownEngagement()
        }
    }

    private func teardownEngagement() {
        stopPollingForActivation()
        ipc.stop()
        IMKProcessManager.terminate()
        boundAppBundleID = nil
    }

    /// Apply a change that was deferred because it arrived mid-dictation.
    private func applyPendingReengage() {
        guard pendingReengage else { return }
        pendingReengage = false
        reconcileEngagement()
    }

    private func enableEngagement() {
        beginListening()
        IMKProcessManager.ensureRunning()
        strategy.activate(memory: memory)
    }

    // MARK: - Dictation insertion path (DictationController)

    /// Whether IMK should handle a dictation right now (the cheap gate checked before
    /// the engage handshake).
    var isAvailableForDictation: Bool {
        settings.imkEnabled && setupState == .ready
    }

    /// Engage IMK for a dictation. Returns true if a client is bound and IMK will
    /// handle insertion; false → the caller falls back to the AX/paste path.
    func beginDictationSession(targetPID: pid_t) -> Bool {
        guard isAvailableForDictation else { return false }
        // Third-party IMEs are suspended in secure (password) fields — don't even try.
        guard !IsSecureEventInputEnabled() else { return false }
        IMKProcessManager.ensureRunning()
        let bound = strategy.beginDictation(targetPID: targetPID, ipc: ipc, memory: memory)
        sessionActive = !bound.isEmpty
        if sessionActive { boundAppBundleID = bound }
        return sessionActive
    }

    /// Stream the in-flight hypothesis as the live underlined composition.
    func renderMarked(_ text: String) {
        guard sessionActive else { return }
        ipc.post(.setMarked, text)
    }

    /// Commit the authoritative final text (replaces the composition), then end the
    /// session. Empty text clears the composition instead of committing.
    func finishDictationSession(finalText: String) {
        guard sessionActive else { return }
        if finalText.isEmpty {
            ipc.post(.clear)
        } else {
            // Acked commit: block until the helper has applied insertText, so a
            // just-in-time source restore (in endDictation) can't deselect the IME
            // before the final text lands and gets lost.
            ipc.request(.commit, finalText, timeout: Self.commitTimeout)
        }
        strategy.endDictation(ipc: ipc, memory: memory)
        sessionActive = false
        applyPendingReengage()
    }

    /// Abort an open IMK session without committing (a safety hook for teardown
    /// paths; the normal close is `finishDictationSession`).
    func cancelDictationSession() {
        guard sessionActive else { return }
        ipc.post(.clear)
        strategy.endDictation(ipc: ipc, memory: memory)
        sessionActive = false
        applyPendingReengage()
    }

    /// Ceiling for the final-commit ack — insertText is fast; this only bounds a
    /// degenerate slow/dead helper.
    private static let commitTimeout: CFTimeInterval = 0.5
}
