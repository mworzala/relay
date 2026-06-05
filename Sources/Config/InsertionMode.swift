import Foundation

/// How a dictation's text lands in the focused field.
///
/// `nonisolated` (like `InjectionMode`) so it can be read off the main actor and
/// persisted in `AppSettings.Snapshot`.
nonisolated enum InsertionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Type the transcript directly into the field as you speak — AX writes or
    /// synthetic keystrokes. The current/default behavior.
    case typeDirectly

    /// Stream the live transcript into Relay's own caret-anchored overlay (the field
    /// is never touched), then paste the final text on release via the clipboard
    /// (⌘V). Robust in Chromium/Electron apps and keeps the caret correct for free.
    case overlayPaste

    var id: String { rawValue }

    /// Short, user-facing label for the settings picker.
    var title: String {
        switch self {
        case .typeDirectly: return "Type directly"
        case .overlayPaste: return "Overlay + paste"
        }
    }
}
