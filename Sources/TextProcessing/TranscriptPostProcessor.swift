import Foundation

/// Single entry point for transcript post-processing: optional ITN (spoken→written
/// number formatting) first, then the user's always-on regex replacement rules —
/// so user rules have the final say over the normalized text.
enum TranscriptPostProcessor {
    @MainActor
    static func apply(_ text: String, settings: AppSettings) -> String {
        var out = text
        if settings.enableITN {
            out = ITNProcessor.process(out)
        }
        out = applyReplacements(out, rules: settings.replacements)
        return out
    }

    /// Apply enabled regex rules in order. An invalid pattern is skipped rather
    /// than crashing; disabled or empty rules are ignored.
    nonisolated static func applyReplacements(_ text: String, rules: [TextReplacementRule]) -> String {
        var out = text
        for rule in rules {
            guard rule.enabled, !rule.pattern.isEmpty else { continue }
            var options: NSRegularExpression.Options = []
            if rule.caseInsensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: options) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(
                in: out, options: [], range: range, withTemplate: rule.replacement)
        }
        return out
    }
}
