import Foundation

/// How Relay's input method engages when "Insert via input method" is on.
///
/// `nonisolated` (like `InsertionMode`) so it can be read off the main actor and
/// persisted in `AppSettings.Snapshot`. Drives which `IMKEngagement` strategy
/// `IMKController` uses; the two modes share all install/IPC/insertion machinery and
/// differ only in *when* Relay's IME is the active input source.
nonisolated enum IMKEngagementMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Relay's IME is selected once and stays the full-time source; dictation is
    /// gated internally. No per-dictation switch, no menu-bar flicker. (Recommended.)
    case alwaysOn

    /// Relay's IME is selected only for the duration of each dictation, then the
    /// previous source is restored. One brief menu-bar flip on each dictation start
    /// (the switch-back is free).
    case justInTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysOn: return "Always on"
        case .justInTime: return "Just-in-time"
        }
    }

    /// One-line explanation for the settings picker.
    var detail: String {
        switch self {
        case .alwaysOn:
            return "Relay stays your active input source; no flicker. Recommended."
        case .justInTime:
            return "Switches only while dictating; brief menu-bar flash on start."
        }
    }
}
