import Foundation

/// How long Relay keeps the microphone capture session **warm** after a dictation,
/// so the next one starts instantly instead of paying the `AVCaptureSession`
/// cold-start (~150–300 ms built-in, up to ~1 s for Bluetooth) that otherwise
/// clips the first word.
///
/// `nonisolated` so it can be read off the main actor and persisted in
/// `AppSettings.Snapshot`.
nonisolated enum MicKeepAlive: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Cold-start every time (mic indicator only during dictation). Most private.
    case disabled
    case seconds15
    case seconds30
    case minute1
    case minutes5
    /// Stay warm the whole time Relay runs — never clips, but the macOS mic
    /// indicator stays on continuously.
    case always

    var id: String { rawValue }

    /// Seconds to stay warm after release: `0` = cool immediately, `.infinity` =
    /// never cool.
    var seconds: TimeInterval {
        switch self {
        case .disabled: return 0
        case .seconds15: return 15
        case .seconds30: return 30
        case .minute1: return 60
        case .minutes5: return 300
        case .always: return .infinity
        }
    }

    /// True when Relay should keep the mic warm even before the first dictation
    /// (i.e. pre-warm at launch).
    var prewarms: Bool { self == .always }

    var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .seconds15: return "15 seconds"
        case .seconds30: return "30 seconds"
        case .minute1: return "1 minute"
        case .minutes5: return "5 minutes"
        case .always: return "Always"
        }
    }
}
