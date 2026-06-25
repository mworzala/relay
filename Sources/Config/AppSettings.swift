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
    /// Double-tap the hold-to-talk key to start a hands-free session that keeps
    /// listening after you release and only stops on the next tap. Default on.
    var enableDoubleTapLock: Bool
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
    /// How long to keep the mic warm after a dictation so the next one starts
    /// instantly (no cold-start clipping the first word). See `MicKeepAlive`.
    var micKeepAlive: MicKeepAlive
    /// Inverse Text Normalization (spoken→written numbers). Toggleable; default off.
    var enableITN: Bool
    /// User-defined find→replace rules, always applied (per-rule enable inside).
    var replacements: [TextReplacementRule]

    /// The exact subset written to disk.
    private struct Snapshot: Codable {
        var micPriority: [MicPriorityEntry]
        var keybind: Keybind
        var launchAtLogin: Bool
        var firstRunComplete: Bool
        var enableDoubleTapLock: Bool?         // added later; nil in old files → default on
        var injectUnconfirmedText: Bool?       // added later; nil in old files → default on
        var insertionMode: InsertionMode?      // added later; nil in old files → .typeDirectly
        var imkEnabled: Bool?                  // added later; nil in old files → false
        var imkEngagementMode: IMKEngagementMode?  // added later; nil in old files → .alwaysOn
        var micKeepAlive: MicKeepAlive?        // added later; nil in old files → .seconds30
        // Optional for backward compatibility with settings.json written before
        // these existed (a missing key must not fail the whole decode).
        var enableITN: Bool?
        var replacements: [TextReplacementRule]?
    }

    init() {
        if let snap = Self.loadSnapshot() {
            micPriority = snap.micPriority
            keybind = snap.keybind
            launchAtLogin = snap.launchAtLogin
            firstRunComplete = snap.firstRunComplete
            enableDoubleTapLock = snap.enableDoubleTapLock ?? true
            injectUnconfirmedText = snap.injectUnconfirmedText ?? true
            insertionMode = snap.insertionMode ?? .typeDirectly
            imkEnabled = snap.imkEnabled ?? false
            imkEngagementMode = snap.imkEngagementMode ?? .alwaysOn
            micKeepAlive = snap.micKeepAlive ?? .seconds30
            enableITN = snap.enableITN ?? false
            replacements = snap.replacements ?? []
        } else {
            micPriority = []
            keybind = .rightCommand
            launchAtLogin = false
            firstRunComplete = false
            enableDoubleTapLock = true
            injectUnconfirmedText = true
            insertionMode = .typeDirectly
            imkEnabled = false
            imkEngagementMode = .alwaysOn
            micKeepAlive = .seconds30
            enableITN = false
            replacements = []
        }
    }

    /// Load the persisted snapshot, distinguishing "no file yet" (legitimate first
    /// run → nil, use defaults silently) from "file exists but won't decode" (a torn
    /// write, disk corruption, manual edit, or future required-field schema change).
    /// In the corrupt case, decoding silently into defaults would reset the keybind,
    /// empty mic priority, and re-trigger onboarding with no trace — so we log it and
    /// rename the bad file to settings.json.corrupt (preserving it for diagnosis)
    /// before the next save overwrites the original.
    private static func loadSnapshot() -> Snapshot? {
        let url = AppPaths.settingsFile
        guard let data = try? Data(contentsOf: url) else {
            return nil   // no file → first run
        }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            NSLog("Relay: settings at \(url.path) failed to decode (\(error)); preserving as .corrupt and resetting to defaults")
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
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
            enableDoubleTapLock: enableDoubleTapLock,
            injectUnconfirmedText: injectUnconfirmedText,
            insertionMode: insertionMode,
            imkEnabled: imkEnabled,
            imkEngagementMode: imkEngagementMode,
            micKeepAlive: micKeepAlive,
            enableITN: enableITN,
            replacements: replacements
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
