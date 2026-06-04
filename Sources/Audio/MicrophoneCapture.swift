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

    @ObservationIgnored private var samplesSink: (@Sendable ([Float]) -> Void)?

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

    /// Start recording. `sink` receives raw input buffers on the audio thread.
    func beginCapture(sink: @escaping @Sendable ([Float]) -> Void) {
        samplesSink = sink
        let device = monitor.activeDevice(for: priorityProvider())
        activeDevice = device
        do {
            try engine.start(deviceUID: device?.uid, onSamples: sink)
            isCapturing = true
        } catch {
            NSLog("Relay: failed to start capture: \(error)")
            isCapturing = false
        }
    }

    func endCapture() {
        engine.stop()
        samplesSink = nil
        isCapturing = false
    }

    /// The persisted priority order changed (user reordered). Re-resolve the
    /// active device and reroute if currently capturing.
    func priorityDidChange() {
        let desired = monitor.activeDevice(for: priorityProvider())
        let changed = desired?.uid != activeDevice?.uid
        activeDevice = desired
        if isCapturing, changed, let sink = samplesSink {
            reroute(to: desired, sink: sink)
        }
    }

    // MARK: Hot-plug handling

    private func handleDeviceChange() {
        let desired = monitor.activeDevice(for: priorityProvider())
        let changed = desired?.uid != activeDevice?.uid
        activeDevice = desired
        if isCapturing, changed, let sink = samplesSink {
            reroute(to: desired, sink: sink)
        }
    }

    private func handleConfigChange() {
        // Hardware format changed (often the active device vanished). Rebuild the
        // tap on the freshly-resolved device so capture continues cleanly.
        guard isCapturing, let sink = samplesSink else { return }
        let desired = monitor.activeDevice(for: priorityProvider())
        activeDevice = desired
        reroute(to: desired, sink: sink)
    }

    private func reroute(to device: AudioInputDevice?, sink: @escaping @Sendable ([Float]) -> Void) {
        do {
            engine.stop()
            try engine.start(deviceUID: device?.uid, onSamples: sink)
            isCapturing = true
            NSLog("Relay: rerouted microphone to \(device?.name ?? "default")")
        } catch {
            NSLog("Relay: reroute failed: \(error)")
            isCapturing = false
        }
    }
}
