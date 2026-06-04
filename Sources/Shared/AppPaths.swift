import Foundation

/// Central filesystem locations for Relay, all under
/// `~/Library/Application Support/Relay/`. Directories are created on first use.
///
/// Marked `nonisolated` so the ASR actor (which downloads models off the main
/// actor) can read these paths without hopping to `@MainActor`.
enum AppPaths {
    /// `~/Library/Application Support/Relay`
    nonisolated static let appSupport: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Relay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `~/Library/Application Support/Relay/Models` — Parakeet v3 lives here
    /// (a Relay subfolder, NOT FluidAudio's default cache).
    nonisolated static let models: URL = {
        let dir = appSupport.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// SwiftData history store file.
    nonisolated static let historyStore: URL =
        appSupport.appendingPathComponent("History.store")

    /// JSON-backed config file (mic priority, keybind, flags).
    nonisolated static let settingsFile: URL =
        appSupport.appendingPathComponent("settings.json")
}
