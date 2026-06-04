import Foundation

/// Conservative, English-focused Inverse Text Normalization: spoken-form numbers
/// → written form. There is no runtime ITN in the Parakeet TDT export (the
/// `<|itn|>` vocab entries are never consumed by the transducer, and FluidAudio's
/// native TextNormalizer isn't linked), so this is a pure Swift post-processor.
///
/// It only transforms clear numeric spans and leaves ambiguous lone words alone
/// (e.g. "I'll be there in a second" is untouched). Passes run in order:
/// ordinals → cardinals → currency → percent, so currency/percent operate on the
/// digits the earlier passes produce.
nonisolated enum ITNProcessor {
    static func process(_ text: String) -> String {
        var out = text
        out = ordinalsPass(out)
        out = cardinalsPass(out)
        out = currencyPass(out)
        out = percentPass(out)
        return out
    }

    // MARK: - Word tables

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    private static let ordinalOnes: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]
    /// Standalone ordinals — deliberately EXCLUDES bare "second" (too often the
    /// time unit, e.g. "in a second"); "second" still resolves in compounds
    /// like "twenty second".
    private static let standaloneOrdinals: [String: Int] = [
        "first": 1, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
        "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60,
        "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]

    // MARK: - Cardinal numbers

    private static func cardinalsPass(_ text: String) -> String {
        let words = Array(units.keys) + Array(tens.keys) + Array(scales.keys) + ["and"]
        // Longest-first so e.g. "sixteen" is tried before "six".
        let alt = words.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = "\\b(?:\(alt))(?:[ \\t]+(?:\(alt)))*\\b"
        return replacing(pattern, in: text, options: [.caseInsensitive]) { groups in
            convertRun(groups[0])
        }
    }

    private static func convertRun(_ matchText: String) -> String {
        let raw = matchText.split { $0 == " " || $0 == "\t" }.map { String($0).lowercased() }
        var core = raw
        var leading: [String] = []
        var trailing: [String] = []
        while core.first == "and" { leading.append("and"); core.removeFirst() }
        while core.last == "and" { trailing.append("and"); core.removeLast() }
        guard !core.isEmpty else { return matchText }   // only "and"s — leave as written
        // Lone "one" is too often non-numeric ("no one", "the one") — leave it.
        if core == ["one"] { return matchText }
        return (leading + [convertCore(core)] + trailing).joined(separator: " ")
    }

    private static func convertCore(_ words: [String]) -> String {
        // Split at "and"; merge a segment ending in a scale with the next one (the
        // "X hundred and Y" case). A bare "and" between plain numbers is a break.
        var segments: [[String]] = [[]]
        for word in words {
            if word == "and" { segments.append([]) } else { segments[segments.count - 1].append(word) }
        }
        segments = segments.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return words.joined(separator: " ") }

        var parts: [String] = []
        var index = 0
        while index < segments.count {
            var segment = segments[index]
            while index + 1 < segments.count, endsWithScale(segment) {
                segment += segments[index + 1]
                index += 1
            }
            parts.append(segmentToDigits(segment))
            index += 1
            if index < segments.count { parts.append("and") }
        }
        return parts.joined(separator: " ")
    }

    private static func endsWithScale(_ segment: [String]) -> Bool {
        guard let last = segment.last else { return false }
        return scales[last] != nil
    }

    private static func segmentToDigits(_ segment: [String]) -> String {
        if segment.contains(where: { scales[$0] != nil }) {
            return String(scaleNumber(segment))
        }
        let groups = parseGroups(segment)
        guard groups.count > 1 else { return String(groups.first ?? 0) }
        // Multiple bare 2-digit groups → a spoken year/sequence ("twenty twenty
        // six" → 2026, "nineteen eighty four" → 1984). Single-digit lead → a plain
        // digit sequence ("one two three" → 123).
        if groups[0] >= 13 {
            return String(groups[0]) + groups.dropFirst().map { String(format: "%02d", $0) }.joined()
        }
        return groups.map(String.init).joined()
    }

    /// Standard words→number for spans that contain a scale word.
    private static func scaleNumber(_ words: [String]) -> Int {
        var total = 0
        var current = 0
        for word in words {
            if let unit = units[word] {
                current += unit
            } else if let ten = tens[word] {
                current += ten
            } else if let scale = scales[word] {
                if scale == 100 {
                    current = (current == 0 ? 1 : current) * 100
                } else {
                    total += (current == 0 ? 1 : current) * scale
                    current = 0
                }
            }
        }
        return total + current
    }

    /// Parse a scale-free span into 2-digit groups: a tens word optionally followed
    /// by a ones word ("twenty six" → 26), or a teen/ones standing alone.
    private static func parseGroups(_ words: [String]) -> [Int] {
        var groups: [Int] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if let unit = units[word] {
                groups.append(unit)
                index += 1
            } else if let ten = tens[word] {
                var value = ten
                if index + 1 < words.count, let ones = units[words[index + 1]], ones < 10 {
                    value += ones
                    index += 2
                } else {
                    index += 1
                }
                groups.append(value)
            } else {
                index += 1
            }
        }
        return groups
    }

    // MARK: - Ordinals

    private static func ordinalsPass(_ text: String) -> String {
        // Compound first ("twenty first" → 21st) so the tens word isn't eaten by
        // the cardinal pass.
        let tensAlt = tens.keys.joined(separator: "|")
        let onesAlt = ordinalOnes.keys.joined(separator: "|")
        var out = replacing(
            "\\b(\(tensAlt))[ \\t]+(\(onesAlt))\\b", in: text, options: [.caseInsensitive]
        ) { groups in
            let value = (tens[groups[1].lowercased()] ?? 0) + (ordinalOnes[groups[2].lowercased()] ?? 0)
            return "\(value)\(ordinalSuffix(value))"
        }

        let standaloneAlt = standaloneOrdinals.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        out = replacing("\\b(\(standaloneAlt))\\b", in: out, options: [.caseInsensitive]) { groups in
            let value = standaloneOrdinals[groups[1].lowercased()] ?? 0
            return "\(value)\(ordinalSuffix(value))"
        }
        return out
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    // MARK: - Currency & percent

    private static func currencyPass(_ text: String) -> String {
        var out = text
        out = replacing("\\b(\\d+) dollars? and (\\d+) cents?\\b", in: out, options: [.caseInsensitive]) {
            "$\($0[1]).\(pad2($0[2]))"
        }
        out = replacing("\\b(\\d+) dollars?\\b", in: out, options: [.caseInsensitive]) { "$\($0[1])" }
        out = replacing("\\b(\\d+) cents?\\b", in: out, options: [.caseInsensitive]) { "$0.\(pad2($0[1]))" }
        return out
    }

    private static func percentPass(_ text: String) -> String {
        replacing("\\b(\\d+) percent\\b", in: text, options: [.caseInsensitive]) { "\($0[1])%" }
    }

    private static func pad2(_ digits: String) -> String {
        digits.count == 1 ? "0" + digits : digits
    }

    // MARK: - Regex replace with a closure (for transforms templates can't express)

    private static func replacing(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [],
        using transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            var groups: [String] = []
            for groupIndex in 0..<match.numberOfRanges {
                let range = match.range(at: groupIndex)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            result += transform(groups)
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }
}
