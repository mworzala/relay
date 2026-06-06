import AVFoundation
import Observation

/// High-level microphone API used by the rest of the app. Ties together device
/// monitoring, priority resolution, and the capture engine: it picks the
/// highest-priority connected device, starts capture on it, and reroutes
/// automatically when devices come and go (fall-down / switch-back).
@MainActor
@Observable
final class MicrophoneCapture {
    private let monitor = AudioDeviceMonitor()
    private let engine = AudioCaptureEngine()

    /// Connected input devices (passthrough; observable).
    var connectedDevices: [AudioInputDevice] { monitor.connectedDevices }
    /// Smoothed input level 0…1 (passthrough; observable).
    var level: Float { engine.level }

    private(set) var activeDevice: AudioInputDevice?
    private(set) var isCapturing = false

    /// Supplies the current persisted priority order (wired to AppSettings).
    @ObservationIgnored var priorityProvider: () -> [MicPriorityEntry] = { [] }
    /// Supplies the current keep-alive policy (wired to AppSettings).
    @ObservationIgnored var keepAliveProvider: () -> MicKeepAlive = { .seconds30 }

    @ObservationIgnored private var samplesSink: (@Sendable ([Float]) -> Void)?
    /// Pending "cool the warm session" task (cancelled when a new dictation starts).
    @ObservationIgnored private var coolTask: Task<Void, Never>?

    /// Whether the capture session is currently running (capturing or warm-idle).
    var isWarm: Bool { engine.isRunning }

    init() {
        monitor.onDevicesChanged = { [weak self] in self?.handleDeviceChange() }
        engine.onConfigurationChange = { [weak self] in self?.handleConfigChange() }
    }

    // MARK: Lifecycle

    /// Begin watching for device hot-plug. Safe to call once at launch.
    func startMonitoring() {
        monitor.start()
        activeDevice = monitor.activeDevice(for: priorityProvider())
    }

    func stopMonitoring() { monitor.stop() }

    /// Latest connected devices, forcing a refresh (used when the config UI opens).
    func refreshDevices() { monitor.refresh() }

    // MARK: Capture

    /// Start recording. `sink` receives raw input buffers on the audio thread. The
    /// session may already be **warm** (kept alive from a previous dictation or
    /// pre-warmed), in which case samples flow immediately — no cold-start gap that
    /// would clip the opening word.
    func beginCapture(sink: @escaping @Sendable ([Float]) -> Void) {
        coolTask?.cancel()
        coolTask = nil
        samplesSink = sink
        let device = monitor.activeDevice(for: priorityProvider())
        activeDevice = device
        do {
            try engine.warm(deviceUID: device?.uid)   // no-op if already warm on this device
            engine.attachSink(sink)
            isCapturing = true
        } catch {
            NSLog("Relay: failed to start capture: \(error)")
            isCapturing = false
        }
    }

    /// Stop feeding the transcriber. The session stays **warm** for the configured
    /// keep-alive window (or forever, for `.always`) so the next dictation is instant;
    /// `.disabled` cools immediately (the old behavior).
    func endCapture() {
        engine.detachSink()
        samplesSink = nil
        isCapturing = false
        scheduleCool(after: keepAliveProvider())
    }

    /// Apply the keep-alive policy outside of an active dictation — pre-warm for
    /// `.always`, or (re)schedule cooling of an idle warm session. Called at launch
    /// and when the setting changes.
    func applyKeepAlivePolicy() {
        guard !isCapturing else { return }   // a live dictation reads the policy at endCapture
        let policy = keepAliveProvider()
        if policy.prewarms {
            coolTask?.cancel(); coolTask = nil
            try? engine.warm(deviceUID: monitor.activeDevice(for: priorityProvider())?.uid)
        } else if engine.isRunning {
            scheduleCool(after: policy)   // a warm-idle session: honor the (possibly new) window
        }
    }

    /// Cool the warm-idle session after the policy's window (immediately for
    /// `.disabled`, never for `.always`).
    private func scheduleCool(after policy: MicKeepAlive) {
        coolTask?.cancel()
        coolTask = nil
        let seconds = policy.seconds
        if seconds == 0 {
            engine.cool()
        } else if seconds.isFinite {
            coolTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, !Task.isCancelled, !self.isCapturing else { return }
                self.engine.cool()
            }
        }
        // .always (infinite) → leave it warm.
    }

    /// The persisted priority order changed (user reordered). Re-resolve the
    /// active device and reroute (or re-warm an idle session) if it changed.
    func priorityDidChange() { rerouteIfDeviceChanged() }

    // MARK: Hot-plug handling

    private func handleDeviceChange() { rerouteIfDeviceChanged() }

    private func handleConfigChange() {
        // Hardware format changed (often the active device vanished). Rebuild on the
        // freshly-resolved device so capture (or the warm session) continues cleanly.
        let desired = monitor.activeDevice(for: priorityProvider())
        activeDevice = desired
        rebuild(to: desired)
    }

    private func rerouteIfDeviceChanged() {
        let desired = monitor.activeDevice(for: priorityProvider())
        let changed = desired?.uid != activeDevice?.uid
        activeDevice = desired
        guard changed else { return }
        rebuild(to: desired)
    }

    /// Move capture (or the warm-idle session) onto `device`. Rebuilds the session on
    /// the new device and re-attaches the dictation sink if we're actively capturing.
    private func rebuild(to device: AudioInputDevice?) {
        guard isCapturing || engine.isRunning else { return }
        do {
            try engine.warm(deviceUID: device?.uid)
            if isCapturing, let sink = samplesSink {
                engine.attachSink(sink)
            }
            NSLog("Relay: microphone now on \(device?.name ?? "default")")
        } catch {
            NSLog("Relay: reroute failed: \(error)")
            if isCapturing { isCapturing = false }
        }
    }
}
