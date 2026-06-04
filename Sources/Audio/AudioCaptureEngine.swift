@preconcurrency import AVFoundation   // AVCaptureSession et al predate Sendable
import FluidAudio
import Observation
import os

enum CaptureError: Error, LocalizedError {
    case deviceNotFound
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "The selected microphone could not be opened."
        case .cannotAddInput: return "Could not add the microphone input to the capture session."
        case .cannotAddOutput: return "Could not add the audio output to the capture session."
        }
    }
}

/// Microphone capture via **AVCaptureSession**, which opens ONLY the explicitly
/// chosen device — it never touches the system default input. (The previous
/// AVAudioEngine implementation realized `inputNode` against the default device,
/// which opened e.g. AirPods and forced a Bluetooth HFP switch even when another
/// device was selected.)
///
/// Vends 16 kHz mono `Float` samples (via FluidAudio's `AudioConverter`) and a
/// smoothed input `level`. The chosen device is resolved by stable UID —
/// `AVCaptureDevice.uniqueID` equals the CoreAudio device UID we persist.
@MainActor
@Observable
final class AudioCaptureEngine {
    private(set) var level: Float = 0
    private(set) var isRunning = false

    /// Called (on the main actor) when the session hits a runtime error — e.g. the
    /// active device was unplugged.
    @ObservationIgnored var onConfigurationChange: (() -> Void)?

    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private var runtimeObserver: NSObjectProtocol?
    @ObservationIgnored private let sampleQueue = DispatchQueue(label: "com.relay.audio.capture")
    @ObservationIgnored private let delegate = SampleDelegate()

    /// Start capturing 16 kHz mono samples from the device with `deviceUID`
    /// (nil / not found → system default audio device). `onSamples` runs on the
    /// capture queue; keep it cheap.
    func start(
        deviceUID: String?,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws {
        stop()

        let device = deviceUID.flatMap { CaptureDeviceResolver.device(forUID: $0) }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw CaptureError.deviceNotFound }

        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        delegate.setHandlers(
            onSamples: onSamples,
            onLevel: { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
        )
        output.setSampleBufferDelegate(delegate, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        runtimeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }

        self.session = session
        // startRunning() blocks; never call it on the main actor.
        sampleQueue.async { session.startRunning() }
        isRunning = true
    }

    func stop() {
        if let runtimeObserver {
            NotificationCenter.default.removeObserver(runtimeObserver)
            self.runtimeObserver = nil
        }
        delegate.setHandlers(onSamples: nil, onLevel: nil)
        if let session {
            sampleQueue.async { session.stopRunning() }
        }
        session = nil
        isRunning = false
        level = 0
    }
}

/// Resolves a persisted device UID to an `AVCaptureDevice`. For HAL audio devices
/// `AVCaptureDevice.uniqueID` is the CoreAudio `kAudioDevicePropertyDeviceUID`.
enum CaptureDeviceResolver {
    static func device(forUID uid: String) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],   // macOS 14+ device-type names
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.first { $0.uniqueID == uid }
    }
}

/// Nonisolated audio-output delegate. It runs on the capture queue (NOT the main
/// actor), so it must opt out of the project's MainActor-by-default isolation —
/// otherwise the callback would trap. Mutable handler state is guarded by a lock.
private nonisolated final class SampleDelegate: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    private struct Handlers: Sendable {
        var onSamples: (@Sendable ([Float]) -> Void)?
        var onLevel: (@Sendable (Float) -> Void)?
    }

    private let converter = AudioConverter()   // FluidAudio; default target 16 kHz mono
    private let handlers = OSAllocatedUnfairLock(initialState: Handlers())

    func setHandlers(
        onSamples: (@Sendable ([Float]) -> Void)?,
        onLevel: (@Sendable (Float) -> Void)?
    ) {
        handlers.withLock { state in
            state.onSamples = onSamples
            state.onLevel = onLevel
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let samples = try? converter.resampleSampleBuffer(sampleBuffer), !samples.isEmpty else {
            return
        }
        let rms = AudioLevelMeter.levels(from: samples).rms
        let level = AudioLevelMeter.normalizedLevel(rms: rms)
        let snapshot = handlers.withLock { $0 }   // copy out; don't call closures under the lock
        snapshot.onLevel?(level)
        snapshot.onSamples?(samples)
    }
}
