import Foundation
import SwiftData

/// One saved dictation result. Backed by SwiftData; stored at
/// `~/Library/Application Support/Relay/History.store` (see HistoryStore).
///
/// The stats fields (`appBundleID`, `appName`, `durationSeconds`, `wordCount`)
/// are all optional or defaulted so SwiftData performs an automatic lightweight
/// migration: rows written before stats existed load with nil app / 0 duration /
/// 0 word count and never crash. See `DictationStats` for how such rows are
/// folded into totals (recompute words from `text` when `wordCount == 0`) and the
/// "Unknown" app bucket.
@Model
final class Transcription {
    @Attribute(.unique) var id: UUID
    var text: String
    var timestamp: Date

    /// Bundle id of the app the dictation was typed into (e.g.
    /// `com.tinyspeck.slackmacgap`); nil for pre-stats rows and manual test entries.
    var appBundleID: String?
    /// Localized app name, for display; nil when unknown.
    var appName: String?
    /// Hold-to-talk duration in seconds (start of dictation → finish); 0 when
    /// unknown (pre-stats rows, manual entries). Excluded from WPM when 0.
    var durationSeconds: Double = 0
    /// Word count, denormalized at insert using `WordCount` so stats aggregation
    /// is cheap. 0 on pre-stats rows (recomputed from `text` by the aggregator).
    var wordCount: Int = 0

    init(
        text: String,
        timestamp: Date = .now,
        appBundleID: String? = nil,
        appName: String? = nil,
        durationSeconds: Double = 0,
        id: UUID = UUID()
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.appName = appName
        self.durationSeconds = durationSeconds
        self.wordCount = WordCount.count(text)
    }

    /// A pure `Sendable` snapshot for the stats aggregator. The single home for the
    /// migrated-row rule: pre-stats rows stored `wordCount == 0`, so recompute from
    /// `text` (otherwise they'd silently drop from totals). Used by both the stats UI
    /// and the persistence tests so the mapping can't drift between them.
    var statsSnapshot: TranscriptionSnapshot {
        TranscriptionSnapshot(
            timestamp: timestamp,
            wordCount: wordCount > 0 ? wordCount : WordCount.count(text),
            characterCount: text.count,
            durationSeconds: durationSeconds,
            appBundleID: appBundleID,
            appName: appName)
    }
}
