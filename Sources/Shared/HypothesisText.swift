import Foundation

/// The single rule for joining a committed prefix and a volatile tail into one
/// line of live hypothesis text: exactly one space between them when both are
/// present, and no leading/trailing space. Centralized so the injection target,
/// the streaming fallback, and the overlay all space the seam identically.
nonisolated enum HypothesisText {
    static func join(confirmed: String, volatile: String) -> String {
        [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
