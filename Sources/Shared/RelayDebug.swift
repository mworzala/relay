import Foundation

/// Centralized debug switches, read once from the environment at launch.
///
/// - `RELAY_DEBUG=1` — broad debug mode: shows the overlay diagnostics strip
///   above the dictation pill **and** implies injector tracing.
/// - `RELAY_DEBUG_INJECT=1` — legacy, tracing only (no overlay strip).
///
/// `make debug-run` sets `RELAY_DEBUG=1`. Default builds show nothing extra.
nonisolated enum RelayDebug {
    /// Show the (extensible) overlay diagnostics strip above the pill.
    static let overlayEnabled = env("RELAY_DEBUG")

    /// Emit per-edit injector tracing via `NSLog`.
    static let injectTracing = env("RELAY_DEBUG") || env("RELAY_DEBUG_INJECT")

    private static func env(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key] == "1"
    }
}
