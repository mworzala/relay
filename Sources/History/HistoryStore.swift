import Foundation
import SwiftData

/// Owns the shared SwiftData container (pinned to Relay's Application Support
/// folder) and offers a tiny programmatic API for non-UI writers (e.g. the ASR
/// pipeline saving a finalized transcript on key-up).
enum HistoryStore {
    @MainActor static let container: ModelContainer = {
        let configuration = ModelConfiguration(url: AppPaths.historyStore)
        do {
            return try ModelContainer(for: Transcription.self, configurations: configuration)
        } catch {
            // A corrupt/incompatible store is a developer-time problem; fail loudly.
            fatalError("Unable to open SwiftData store at \(AppPaths.historyStore.path): \(error)")
        }
    }()

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
        try? context.save()
    }
}
