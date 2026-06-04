import Foundation
import SwiftData

/// One saved dictation result. Backed by SwiftData; stored at
/// `~/Library/Application Support/Relay/History.store` (see HistoryStore).
@Model
final class Transcription {
    @Attribute(.unique) var id: UUID
    var text: String
    var timestamp: Date

    init(text: String, timestamp: Date = .now, id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}
