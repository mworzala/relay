import Foundation
import Observation
import FluidAudio

/// Lifecycle of the speech model as the config UI sees it.
enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(Double)   // 0...1
    case loading
    case ready
    case error(String)
}

/// Owns the Parakeet v3 model + batch `AsrManager` for the app. Surfaces a
/// `ModelStatus` for the UI and prepares/loads on demand (the first-run wizard or
/// the Model section drive `prepare()`). Streaming lives separately (M5).
@MainActor
@Observable
final class ASREngine {
    private(set) var status: ModelStatus

    /// The loaded models, shared with the streaming manager once that exists.
    private(set) var models: AsrModels?
    private var manager: AsrManager?

    init() {
        status = ParakeetModel.isDownloaded() ? .loading : .notDownloaded
    }

    var isReady: Bool { status == .ready }

    /// The loaded batch manager, shared with the streaming transcriber for the
    /// LocalAgreement passes and the final full-buffer pass.
    var asrManager: AsrManager? { manager }

    /// Download (if needed), load the models, and attach the batch manager.
    /// Idempotent-ish: no-ops while already downloading/loading.
    func prepare() async {
        // Don't restart an in-flight download, or reload when already attached.
        if case .downloading = status { return }
        if case .loading = status, manager != nil { return }

        do {
            let loaded: AsrModels
            if ParakeetModel.isDownloaded() {
                status = .loading
                loaded = try await ParakeetModel.load()
            } else {
                status = .downloading(0)
                loaded = try await ParakeetModel.downloadAndLoad(progress: { [weak self] progress in
                    guard let self else { return }
                    let phase = progress.phase
                    let frac = progress.fractionCompleted
                    Task { @MainActor in
                        switch phase {
                        case .compiling: self.status = .loading
                        default: self.status = .downloading(frac)
                        }
                    }
                })
                status = .loading
            }

            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(loaded)
            self.models = loaded
            self.manager = mgr
            status = .ready
        } catch {
            status = .error(Self.describe(error))
        }
    }

    func retry() async {
        status = ParakeetModel.isDownloaded() ? .loading : .notDownloaded
        await prepare()
    }

    /// Batch-transcribe a complete audio file (any AVAudioFile-readable format;
    /// FluidAudio converts to 16 kHz mono internally). Returns nil if not ready.
    func transcribe(fileURL: URL, language: Language? = nil) async -> ASRResult? {
        guard let manager else { return nil }
        do {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(fileURL, decoderState: &state, language: language)
        } catch {
            NSLog("Relay: batch transcription failed: \(error)")
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
