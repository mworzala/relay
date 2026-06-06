import Foundation
import Observation

/// Observable, JSON-persisted app configuration. Lives on the main actor (it is
/// UI state); the only persisted concerns are mic priority, the keybind, the
/// launch-at-login preference, and the first-run flag.
///
/// History is NOT here — it's in SwiftData (see HistoryStore). Models are not
/// here either — they live on disk under AppPaths.models.
@MainActor
@Observable
final class AppSettings {
    var micPriority: [MicPriorityEntry]
    var keybind: Keybind
    var launchAtLogin: Bool
    var firstRunComplete: Bool
    /// Type low-confidence words live and correct them as you speak (responsive,
    /// may briefly rewrite/backspace). Off = inject only the committed prefix
    /// (smooth, append-only, slightly delayed). Default on.
    var injectUnconfirmedText: Bool
    /// Whether dictation types directly into the field (default) or streams into a
    /// caret-anchored overlay and pastes on release. See `InsertionMode`.
    var insertionMode: InsertionMode
    /// Opt-in, experimental: route insertion through Relay's input method (better
    /// Electron/Chromium support) when installed/engaged, falling back to the AX/paste
    /// path otherwise. Off by default. See plan 08 / `IMKController`.
    var imkEnabled: Bool
    /// How the input method engages when `imkEnabled` is on. See `IMKEngagementMode`.
    var imkEngagementMode: IMKEngagementMode

    /// The exact subset written to disk.
    private struct Snapshot: Codable {
        var micPriority: [MicPriorityEntry]
        var keybind: Keybind
        var launchAtLogin: Bool
        var firstRunComplete: Bool
        var injectUnconfirmedText: Bool?       // added later; nil in old files → default on
        var insertionMode: InsertionMode?      // added later; nil in old files → .typeDirectly
        var imkEnabled: Bool?                  // added later; nil in old files → false
        var imkEngagementMode: IMKEngagementMode?  // added later; nil in old files → .alwaysOn
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.settingsFile),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            micPriority = snap.micPriority
            keybind = snap.keybind
            launchAtLogin = snap.launchAtLogin
            firstRunComplete = snap.firstRunComplete
            injectUnconfirmedText = snap.injectUnconfirmedText ?? true
            insertionMode = snap.insertionMode ?? .typeDirectly
            imkEnabled = snap.imkEnabled ?? false
            imkEngagementMode = snap.imkEngagementMode ?? .alwaysOn
        } else {
            micPriority = []
            keybind = .rightCommand
            launchAtLogin = false
            firstRunComplete = false
            injectUnconfirmedText = true
            insertionMode = .typeDirectly
            imkEnabled = false
            imkEngagementMode = .alwaysOn
        }
    }

    /// Persist the current values. Callers invoke this after mutating settings;
    /// kept explicit (rather than didSet) so it composes cleanly with @Observable.
    func save() {
        let snap = Snapshot(
            micPriority: micPriority,
            keybind: keybind,
            launchAtLogin: launchAtLogin,
            firstRunComplete: firstRunComplete,
            injectUnconfirmedText: injectUnconfirmedText,
            insertionMode: insertionMode,
            imkEnabled: imkEnabled,
            imkEngagementMode: imkEngagementMode
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snap).write(to: AppPaths.settingsFile, options: .atomic)
        } catch {
            NSLog("Relay: failed to save settings: \(error)")
        }
    }
}
