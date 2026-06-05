import Foundation

/// A `Sendable` value copy of one dictation, lifted out of the SwiftData
/// `Transcription` model so the aggregator is pure, off-actor, and unit-testable
/// without a store. The UI maps live `@Query` results into these; tests build
/// them by hand.
///
/// `wordCount` is the denormalized count from the model — but pre-stats rows
/// stored 0, so callers should pass the recomputed `WordCount.count(text)` when
/// the stored value is 0 (see `StatsSection`). `durationSeconds == 0` means
/// "unknown" (pre-stats / manual rows) and is excluded from WPM and time totals.
nonisolated struct TranscriptionSnapshot: Sendable, Equatable {
    let timestamp: Date
    let wordCount: Int
    let characterCount: Int
    let durationSeconds: Double
    let appBundleID: String?
    let appName: String?

    init(
        timestamp: Date,
        wordCount: Int,
        characterCount: Int = 0,
        durationSeconds: Double,
        appBundleID: String?,
        appName: String?
    ) {
        self.timestamp = timestamp
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.durationSeconds = durationSeconds
        self.appBundleID = appBundleID
        self.appName = appName
    }
}

/// The window stats are computed over. Period filtering is by calendar day (in
/// the supplied calendar), so "today" is since local midnight and "last 7 days"
/// is today plus the previous six calendar days.
nonisolated enum StatPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, last7Days, last30Days, allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "7 Days"
        case .last30Days: return "30 Days"
        case .allTime: return "All Time"
        }
    }

    /// Inclusive lower bound for `timestamp`, or nil for `.allTime` (no filter).
    func startDate(now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today: return startOfToday
        case .last7Days: return calendar.date(byAdding: .day, value: -6, to: startOfToday)
        case .last30Days: return calendar.date(byAdding: .day, value: -29, to: startOfToday)
        case .allTime: return nil
        }
    }
}

/// Per-application slice of the stats. `appBundleID == nil` is the catch-all
/// "Unknown" bucket (pre-stats rows, manual entries, focus we couldn't resolve).
nonisolated struct AppStat: Sendable, Equatable, Identifiable {
    let appBundleID: String?
    let appName: String
    let words: Int
    let sessions: Int
    let durationSeconds: Double
    /// WPM over this app's qualifying sessions (duration ≥ floor); nil if none.
    let wpm: Double?

    var isUnknown: Bool { appBundleID == nil }
    var id: String { appBundleID ?? "\u{0}unknown" }
}

/// One calendar day in the recent-activity trend.
nonisolated struct DayBucket: Sendable, Equatable, Identifiable {
    let date: Date    // start of day, in the computing calendar
    let words: Int
    var id: Date { date }
}

/// Pure usage statistics derived from dictation history. Everything here is a
/// snapshot for a single `(period, now)`; recompute when either changes.
nonisolated struct DictationStats: Sendable, Equatable {
    let period: StatPeriod

    // Totals over the period-filtered set.
    let totalWords: Int
    let totalSessions: Int
    let totalCharacters: Int
    /// Sum of known durations (durationSeconds > 0); excludes unknown-duration rows.
    let totalDurationSeconds: Double

    // Words per minute. Qualifying = sessions with duration ≥ `wpmFloor`.
    /// Headline WPM: qualifying words ÷ qualifying minutes. nil if nothing qualifies.
    let aggregateWPM: Double?
    /// Mean of each qualifying session's own WPM. nil if nothing qualifies.
    let averageSessionWPM: Double?

    // Averages.
    let averageWordsPerSession: Double?   // nil when there are no sessions
    let averageSessionDuration: Double?   // over known-duration sessions; nil if none

    // Extremes (over the period-filtered set; 0 when empty).
    let longestSessionWords: Int
    let longestSessionDuration: Double

    // Breakdowns.
    /// Sorted by words desc; the "Unknown" bucket is always last.
    let perApp: [AppStat]
    /// Last 30 calendar days from `now`, oldest → newest, over *all* history
    /// (independent of the selected period — a stable recent-activity sparkline).
    let dailyTrend: [DayBucket]

    /// Earliest dictation in all of history (independent of period); nil if empty.
    let firstDictationDate: Date?

    /// Sessions shorter than this (seconds) are excluded from WPM so a stray
    /// sub-second hold can't inflate the rate toward infinity.
    static let wpmFloor: Double = 0.5

    /// Top app by words (excluding the Unknown bucket).
    var mostUsedAppByWords: AppStat? { perApp.first { !$0.isUnknown } }
    /// Top app by session count (excluding the Unknown bucket).
    var mostUsedAppBySessions: AppStat? {
        perApp.filter { !$0.isUnknown }.max { $0.sessions < $1.sessions }
    }

    /// Aggregate `snapshots` into stats for `period` relative to `now`.
    static func compute(
        from snapshots: [TranscriptionSnapshot],
        now: Date,
        period: StatPeriod,
        calendar: Calendar = .current
    ) -> DictationStats {
        let lowerBound = period.startDate(now: now, calendar: calendar)
        let filtered = lowerBound.map { lb in snapshots.filter { $0.timestamp >= lb } } ?? snapshots

        let totalWords = filtered.reduce(0) { $0 + $1.wordCount }
        let totalSessions = filtered.count
        let totalCharacters = filtered.reduce(0) { $0 + $1.characterCount }

        let known = filtered.filter { $0.durationSeconds > 0 }
        let totalDuration = known.reduce(0.0) { $0 + $1.durationSeconds }

        let qualifying = filtered.filter { $0.durationSeconds >= wpmFloor }
        let qualifyingWords = qualifying.reduce(0) { $0 + $1.wordCount }
        let qualifyingSeconds = qualifying.reduce(0.0) { $0 + $1.durationSeconds }
        let aggregateWPM = qualifyingSeconds > 0
            ? Double(qualifyingWords) / (qualifyingSeconds / 60)
            : nil
        let averageSessionWPM = qualifying.isEmpty
            ? nil
            : qualifying.reduce(0.0) { $0 + Double($1.wordCount) / ($1.durationSeconds / 60) }
                / Double(qualifying.count)

        let averageWordsPerSession = totalSessions > 0
            ? Double(totalWords) / Double(totalSessions)
            : nil
        let averageSessionDuration = known.isEmpty ? nil : totalDuration / Double(known.count)

        let longestWords = filtered.map(\.wordCount).max() ?? 0
        let longestDuration = filtered.map(\.durationSeconds).max() ?? 0

        return DictationStats(
            period: period,
            totalWords: totalWords,
            totalSessions: totalSessions,
            totalCharacters: totalCharacters,
            totalDurationSeconds: totalDuration,
            aggregateWPM: aggregateWPM,
            averageSessionWPM: averageSessionWPM,
            averageWordsPerSession: averageWordsPerSession,
            averageSessionDuration: averageSessionDuration,
            longestSessionWords: longestWords,
            longestSessionDuration: longestDuration,
            perApp: aggregateByApp(filtered),
            dailyTrend: trend(from: snapshots, now: now, days: 30, calendar: calendar),
            firstDictationDate: snapshots.map(\.timestamp).min()
        )
    }

    // MARK: - Helpers

    private static func aggregateByApp(_ records: [TranscriptionSnapshot]) -> [AppStat] {
        var groups: [String?: [TranscriptionSnapshot]] = [:]
        for record in records {
            groups[record.appBundleID, default: []].append(record)
        }

        var stats = groups.map { bundleID, recs -> AppStat in
            let words = recs.reduce(0) { $0 + $1.wordCount }
            let duration = recs.reduce(0.0) { $0 + $1.durationSeconds }
            let qualifying = recs.filter { $0.durationSeconds >= wpmFloor }
            let qualifyingSeconds = qualifying.reduce(0.0) { $0 + $1.durationSeconds }
            let qualifyingWords = qualifying.reduce(0) { $0 + $1.wordCount }
            let wpm = qualifyingSeconds > 0 ? Double(qualifyingWords) / (qualifyingSeconds / 60) : nil
            // Display name: the most recent non-nil name. Sort within the group by
            // timestamp so this is independent of the caller's input ordering (the
            // app a bundle id last reported itself under wins); else the bundle id,
            // else "Unknown".
            let name = recs.sorted { $0.timestamp > $1.timestamp }
                .compactMap(\.appName).first ?? bundleID ?? "Unknown"
            return AppStat(
                appBundleID: bundleID,
                appName: name,
                words: words,
                sessions: recs.count,
                durationSeconds: duration,
                wpm: wpm
            )
        }

        // Words desc; Unknown bucket always last; stable name tiebreak.
        stats.sort { a, b in
            if a.isUnknown != b.isUnknown { return !a.isUnknown }
            if a.words != b.words { return a.words > b.words }
            return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
        }
        return stats
    }

    private static func trend(
        from records: [TranscriptionSnapshot],
        now: Date,
        days: Int,
        calendar: Calendar
    ) -> [DayBucket] {
        var wordsByDay: [Date: Int] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.timestamp)
            wordsByDay[day, default: 0] += record.wordCount
        }

        let startOfToday = calendar.startOfDay(for: now)
        var buckets: [DayBucket] = []
        buckets.reserveCapacity(days)
        for offset in stride(from: -(days - 1), through: 0, by: 1) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            buckets.append(DayBucket(date: day, words: wordsByDay[day] ?? 0))
        }
        return buckets
    }
}
