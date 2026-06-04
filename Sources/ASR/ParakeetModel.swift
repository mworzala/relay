import Foundation
import FluidAudio

/// SwiftUI/Observation-free core for the Parakeet v3 model: where it lives on
/// disk and the download/load primitives. Shared by the app's `ASREngine` and the
/// headless `relay-asr-probe` diagnostic target.
enum ParakeetModel {
    /// `~/Library/Application Support/Relay/Models/parakeet-tdt-0.6b-v3`.
    ///
    /// IMPORTANT (verified against FluidAudio AsrModels.swift): the download/load
    /// APIs take the PARENT of this URL (`directory.deletingLastPathComponent()`)
    /// and re-append the repo folder name (`parakeet-tdt-0.6b-v3`). So the last
    /// path component here MUST equal that repo folder name for `download`,
    /// `load`, and `modelsExist` to all agree on one location. With this value the
    /// files land at exactly this path, under Relay's own Models dir (not
    /// FluidAudio's default `…/FluidAudio/Models/`).
    nonisolated static let repoFolderName = "parakeet-tdt-0.6b-v3"

    nonisolated static let directory: URL =
        AppPaths.models.appendingPathComponent(repoFolderName, isDirectory: true)

    /// True if a complete model bundle already exists on disk (no network).
    nonisolated static func isDownloaded() -> Bool {
        AsrModels.modelsExist(at: directory, version: .v3)
    }

    /// Download (if missing) and load the CoreML models into memory.
    /// `progress` is FluidAudio's `@Sendable` handler, called on an unspecified
    /// queue — hop to the main actor inside it before touching UI.
    static func downloadAndLoad(
        progress: DownloadUtils.ProgressHandler? = nil
    ) async throws -> AsrModels {
        try await AsrModels.downloadAndLoad(
            to: directory,
            version: .v3,
            encoderPrecision: .int8,
            progressHandler: progress
        )
    }

    /// Load already-downloaded models without touching the network.
    static func load() async throws -> AsrModels {
        try await AsrModels.load(from: directory, version: .v3, encoderPrecision: .int8)
    }
}
