import Foundation

/// One user-defined find→replace rule applied to dictated text. `pattern` is a
/// regular expression and `replacement` an `NSRegularExpression` template (so
/// capture groups like `$1` work). Persisted in settings.json.
nonisolated struct TextReplacementRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: UUID
    var pattern: String
    var replacement: String
    var caseInsensitive: Bool
    var enabled: Bool

    init(
        id: UUID = UUID(),
        pattern: String = "",
        replacement: String = "",
        caseInsensitive: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.caseInsensitive = caseInsensitive
        self.enabled = enabled
    }
}
