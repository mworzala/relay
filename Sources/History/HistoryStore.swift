import Foundation
import SwiftData

/// Owns the shared SwiftData container (pinned to Relay's Application Support
/// folder) and offers a tiny programmatic API for non-UI writers (e.g. the ASR
/// pipeline saving a finalized transcript on key-up).
enum HistoryStore {
    @MainActor static let container: ModelContainer = makeContainer()

    /// Open the on-disk store, degrading gracefully rather than crashing. A
    /// corrupt/incompatible store is a real end-user reality (OS update, partial
    /// write, schema drift between Relay versions, disk pressure) and history is a
    /// secondary feature — it must never take the whole dictation app down at
    /// launch. So: try the store; on failure move the bad file aside and retry once
    /// from a clean store; if even that fails, fall back to an in-memory store so
    /// history is merely empty this session.
    @MainActor
    private static func makeContainer() -> ModelContainer {
        let url = AppPaths.historyStore
        do {
            return try ModelContainer(for: Transcription.self,
                                      configurations: ModelConfiguration(url: url))
        } catch {
            NSLog("Relay: history store at \(url.path) failed to open (\(error)); recreating")
        }

        moveAside(url)
        do {
            return try ModelContainer(for: Transcription.self,
                                      configurations: ModelConfiguration(url: url))
        } catch {
            NSLog("Relay: history store recreate failed (\(error)); using in-memory store")
        }

        do {
            return try ModelContainer(for: Transcription.self,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            // An in-memory container with a valid schema cannot realistically fail.
            fatalError("Unable to open even an in-memory SwiftData store: \(error)")
        }
    }

    /// Rename a corrupt store (and its -wal/-shm sidecars) out of the way so the
    /// retry starts clean. Best-effort: failures here just mean the retry will hit
    /// the same bad file and fall through to the in-memory store.
    @MainActor
    private static func moveAside(_ url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard fm.fileExists(atPath: path) else { continue }
            let backup = path + ".corrupt"
            try? fm.removeItem(atPath: backup)
            try? fm.moveItem(atPath: path, toPath: backup)
        }
    }

    /// Insert a finalized transcription and persist immediately. The stats fields
    /// default so existing callers (and the manual-add test field) stay valid; the
    /// dictation pipeline passes the resolved target app and hold duration.
    @MainActor
    static func add(
        _ text: String,
        timestamp: Date = .now,
        appBundleID: String? = nil,
        appName: String? = nil,
        durationSeconds: Double = 0
    ) {
        let context = container.mainContext
        context.insert(Transcription(
            text: text,
            timestamp: timestamp,
            appBundleID: appBundleID,
            appName: appName,
            durationSeconds: durationSeconds
        ))
        save(context, op: "add transcription")
    }

    /// Save the context, logging (never silently swallowing) any failure. A dropped
    /// save loses a finalized transcript and silently undercounts stats, so the
    /// error must at least reach the logs (mirrors AppSettings.save).
    @MainActor
    static func save(_ context: ModelContext, op: String) {
        do {
            try context.save()
        } catch {
            NSLog("Relay: failed to save history (\(op)): \(error)")
        }
    }
}
