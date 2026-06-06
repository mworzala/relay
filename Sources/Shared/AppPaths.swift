import Foundation

/// Central filesystem locations for Relay under `~/Library/Application Support/`.
/// Directories are created on first use.
///
/// **Variant separation:** a locally-built *dev* copy and an *installed* copy run
/// as distinct apps (different bundle ids; see project.yml `RELAY_VARIANT_SUFFIX`)
/// so they don't fight over TCC grants or settings. Their mutable *state*
/// (settings + history) therefore lives in per-variant folders — `Relay` for the
/// release/installed build, `Relay-Dev` for the Debug build — keyed off the
/// `RelayStateDirName` Info.plist value. The large, read-only **model cache is
/// deliberately shared** (folder `Relay`) so a dev build doesn't re-download
/// Parakeet. A target with no Info.plist (the probe) falls back to `Relay`.
///
/// Marked `nonisolated` so the ASR actor (which downloads models off the main
/// actor) can read these paths without hopping to `@MainActor`.
enum AppPaths {
    /// Shared base: `~/Library/Application Support/Relay`. Holds the model cache,
    /// shared across variants.
    nonisolated static let sharedSupport: URL = makeDirectory(named: "Relay")

    /// Per-variant base: `~/Library/Application Support/<RelayStateDirName>`. Holds
    /// settings + history so a dev build and an installed build don't co-mingle them.
    nonisolated static let stateSupport: URL = makeDirectory(named: stateDirectoryName)

    /// `~/Library/Application Support/Relay/Models` — Parakeet v3 lives here (a Relay
    /// subfolder, NOT FluidAudio's default cache). Shared across variants.
    nonisolated static let models: URL = {
        let dir = sharedSupport.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// SwiftData history store file (per-variant).
    nonisolated static let historyStore: URL =
        stateSupport.appendingPathComponent("History.store")

    /// JSON-backed config file (per-variant).
    nonisolated static let settingsFile: URL =
        stateSupport.appendingPathComponent("settings.json")

    // MARK: - Helpers

    /// The per-variant state directory name from the bundle's `RelayStateDirName`
    /// (set per build configuration), defaulting to `Relay`.
    nonisolated private static var stateDirectoryName: String {
        (Bundle.main.object(forInfoDictionaryKey: "RelayStateDirName") as? String) ?? "Relay"
    }

    nonisolated private static func makeDirectory(named name: String) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
