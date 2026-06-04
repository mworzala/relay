import Foundation

/// One microphone in the user's priority order, persisted by its **stable Core
/// Audio device UID** (never by name or index, which are unstable). `name` is the
/// last-known display name, kept so disconnected devices can still be shown
/// (greyed out) and reordered.
struct MicPriorityEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    var uid: String
    var name: String

    var id: String { uid }
}
