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

    /// Insert a finalized transcription and persist immediately.
    @MainActor
    static func add(_ text: String, timestamp: Date = .now) {
        let context = container.mainContext
        context.insert(Transcription(text: text, timestamp: timestamp))
        try? context.save()
    }
}
