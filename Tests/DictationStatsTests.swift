import XCTest
@testable import Relay

/// Unit tests for the pure `DictationStats.compute` aggregator and the shared
/// `WordCount` definition. `nonisolated` because the project defaults types to
/// the MainActor; these run off it. A fixed UTC calendar + fixed `now` keep
/// calendar-day period filtering deterministic across machines/timezones.
nonisolated final class DictationStatsTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Noon on a fixed day, so a record placed "N days ago at noon" stays cleanly
    /// inside its own calendar day.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 12))!
    }

    private func snap(
        daysAgo: Int,
        words: Int,
        chars: Int = 0,
        dur: Double,
        bundle: String?,
        name: String?
    ) -> TranscriptionSnapshot {
        let ts = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return TranscriptionSnapshot(
            timestamp: ts, wordCount: words, characterCount: chars,
            durationSeconds: dur, appBundleID: bundle, appName: name)
    }

    private func stats(_ snaps: [TranscriptionSnapshot], _ period: StatPeriod) -> DictationStats {
        DictationStats.compute(from: snaps, now: now, period: period, calendar: calendar)
    }

    // MARK: - Period filtering

    /// Words by period: today=10, 7d=+20, 30d=+30, all=+40 → cumulative 10/30/60/100.
    private var periodFixture: [TranscriptionSnapshot] {
        [
            snap(daysAgo: 0, words: 10, chars: 50, dur: 6, bundle: "com.a", name: "Alpha"),
            snap(daysAgo: 3, words: 20, chars: 100, dur: 12, bundle: "com.a", name: "Alpha"),
            snap(daysAgo: 10, words: 30, chars: 150, dur: 18, bundle: "com.b", name: "Beta"),
            snap(daysAgo: 40, words: 40, chars: 200, dur: 24, bundle: "com.b", name: "Beta"),
        ]
    }

    func testPeriodTodayOnlyToday() {
        XCTAssertEqual(stats(periodFixture, .today).totalWords, 10)
        XCTAssertEqual(stats(periodFixture, .today).totalSessions, 1)
    }

    func testPeriodLast7Days() {
        XCTAssertEqual(stats(periodFixture, .last7Days).totalWords, 30)
        XCTAssertEqual(stats(periodFixture, .last7Days).totalSessions, 2)
    }

    func testPeriodLast30Days() {
        XCTAssertEqual(stats(periodFixture, .last30Days).totalWords, 60)
        XCTAssertEqual(stats(periodFixture, .last30Days).totalSessions, 3)
    }

    func testPeriodAllTime() {
        XCTAssertEqual(stats(periodFixture, .allTime).totalWords, 100)
        XCTAssertEqual(stats(periodFixture, .allTime).totalSessions, 4)
        XCTAssertEqual(stats(periodFixture, .allTime).totalCharacters, 500)
    }

    func testFirstDictationDateIsIndependentOfPeriod() {
        // Earliest across ALL history, even when the period excludes it.
        let expected = calendar.date(byAdding: .day, value: -40, to: now)!
        XCTAssertEqual(stats(periodFixture, .today).firstDictationDate, expected)
        XCTAssertEqual(stats(periodFixture, .allTime).firstDictationDate, expected)
    }

    // MARK: - WPM math (floor + unknown-duration exclusion)

    /// A: 100w/30s (200 wpm), B: 50w/60s (50 wpm), C: 5w/0.3s (< floor → excluded),
    /// D: 25w/0s (unknown duration → excluded from WPM + time, counted in words).
    private var wpmFixture: [TranscriptionSnapshot] {
        [
            snap(daysAgo: 0, words: 100, dur: 30, bundle: "com.x", name: "X"),
            snap(daysAgo: 0, words: 50, dur: 60, bundle: "com.x", name: "X"),
            snap(daysAgo: 0, words: 5, dur: 0.3, bundle: "com.x", name: "X"),
            snap(daysAgo: 0, words: 25, dur: 0, bundle: "com.y", name: "Y"),
        ]
    }

    func testTotalWordsCountsUnknownAndSubFloor() {
        XCTAssertEqual(stats(wpmFixture, .allTime).totalWords, 180)
        XCTAssertEqual(stats(wpmFixture, .allTime).totalSessions, 4)
    }

    func testAggregateWPMUsesOnlyQualifyingSessions() throws {
        // (100 + 50) words ÷ ((30 + 60) / 60) minutes = 150 / 1.5 = 100.
        let wpm = try XCTUnwrap(stats(wpmFixture, .allTime).aggregateWPM)
        XCTAssertEqual(wpm, 100, accuracy: 0.0001)
    }

    func testAverageSessionWPMDiffersFromAggregate() throws {
        // mean(200, 50) = 125 — distinct from the 100 aggregate, proving it's the
        // per-session mean, not the pooled rate.
        let avg = try XCTUnwrap(stats(wpmFixture, .allTime).averageSessionWPM)
        XCTAssertEqual(avg, 125, accuracy: 0.0001)
    }

    func testTotalDurationExcludesUnknownButKeepsSubFloor() {
        // 30 + 60 + 0.3 (C kept — it's real time) ; D's 0 excluded.
        XCTAssertEqual(stats(wpmFixture, .allTime).totalDurationSeconds, 90.3, accuracy: 0.0001)
    }

    func testAverageSessionDurationOverKnownDurations() throws {
        // 90.3 / 3 known-duration sessions (A, B, C); D excluded.
        let avg = try XCTUnwrap(stats(wpmFixture, .allTime).averageSessionDuration)
        XCTAssertEqual(avg, 30.1, accuracy: 0.0001)
    }

    func testAverageWordsPerSessionCountsAllSessions() throws {
        let avg = try XCTUnwrap(stats(wpmFixture, .allTime).averageWordsPerSession)
        XCTAssertEqual(avg, 45, accuracy: 0.0001)   // 180 / 4
    }

    func testLongestSelection() {
        let s = stats(wpmFixture, .allTime)
        XCTAssertEqual(s.longestSessionWords, 100)
        XCTAssertEqual(s.longestSessionDuration, 60, accuracy: 0.0001)
    }

    func testNoQualifyingSessionsYieldsNilWPM() {
        let onlyShortOrUnknown = [
            snap(daysAgo: 0, words: 5, dur: 0.2, bundle: "com.x", name: "X"),
            snap(daysAgo: 0, words: 8, dur: 0, bundle: "com.y", name: "Y"),
        ]
        let s = stats(onlyShortOrUnknown, .allTime)
        XCTAssertNil(s.aggregateWPM)
        XCTAssertNil(s.averageSessionWPM)
        XCTAssertEqual(s.totalWords, 13)   // still counted
    }

    // MARK: - Per-app grouping (incl. Unknown bucket)

    private var perAppFixture: [TranscriptionSnapshot] {
        [
            snap(daysAgo: 0, words: 30, dur: 60, bundle: "com.a", name: "Alpha"),
            snap(daysAgo: 0, words: 10, dur: 30, bundle: "com.a", name: "Alpha"),
            snap(daysAgo: 0, words: 50, dur: 60, bundle: "com.b", name: "Beta"),
            snap(daysAgo: 0, words: 5, dur: 0, bundle: nil, name: nil),
            snap(daysAgo: 0, words: 100, dur: 0, bundle: nil, name: nil),
        ]
    }

    func testPerAppSortedWordsDescUnknownLast() {
        let perApp = stats(perAppFixture, .allTime).perApp
        XCTAssertEqual(perApp.count, 3)
        // Beta (50) before Alpha (40); Unknown (105) forced last despite most words.
        XCTAssertEqual(perApp[0].appName, "Beta")
        XCTAssertEqual(perApp[0].words, 50)
        XCTAssertEqual(perApp[1].appName, "Alpha")
        XCTAssertEqual(perApp[1].words, 40)
        XCTAssertTrue(perApp[2].isUnknown)
        XCTAssertEqual(perApp[2].appName, "Unknown")
        XCTAssertEqual(perApp[2].words, 105)
    }

    func testPerAppSessionsAndWPM() throws {
        let perApp = stats(perAppFixture, .allTime).perApp
        let alpha = try XCTUnwrap(perApp.first { $0.appBundleID == "com.a" })
        XCTAssertEqual(alpha.sessions, 2)
        XCTAssertEqual(alpha.durationSeconds, 90, accuracy: 0.0001)
        // (30 + 10) words ÷ ((60 + 30)/60) min = 40 / 1.5 ≈ 26.67
        XCTAssertEqual(try XCTUnwrap(alpha.wpm), 40.0 / 1.5, accuracy: 0.0001)
        // Unknown has only zero-duration sessions → no WPM.
        let unknown = try XCTUnwrap(perApp.first { $0.isUnknown })
        XCTAssertNil(unknown.wpm)
        XCTAssertEqual(unknown.sessions, 2)
    }

    func testMostUsedApp() throws {
        let s = stats(perAppFixture, .allTime)
        // Most words (excluding Unknown) = Beta; most sessions = Alpha (2).
        XCTAssertEqual(try XCTUnwrap(s.mostUsedAppByWords).appName, "Beta")
        XCTAssertEqual(try XCTUnwrap(s.mostUsedAppBySessions).appName, "Alpha")
    }

    func testUnknownBucketFallsBackToBundleIDThenUnknown() {
        let recs = [
            snap(daysAgo: 0, words: 3, dur: 0, bundle: "com.noname", name: nil),
            snap(daysAgo: 0, words: 4, dur: 0, bundle: nil, name: nil),
        ]
        let perApp = stats(recs, .allTime).perApp
        // A bundle id with no localized name displays the bundle id, not "Unknown".
        XCTAssertEqual(perApp.first { $0.appBundleID == "com.noname" }?.appName, "com.noname")
        XCTAssertEqual(perApp.first { $0.isUnknown }?.appName, "Unknown")
    }

    func testAppNameUsesMostRecentRegardlessOfInputOrder() {
        // Same bundle id reported under two names at different times. The newest
        // name must win whichever order the snapshots arrive in.
        let older = snap(daysAgo: 5, words: 1, dur: 0, bundle: "com.a", name: "OldName")
        let newer = snap(daysAgo: 0, words: 1, dur: 0, bundle: "com.a", name: "NewName")
        for input in [[older, newer], [newer, older]] {
            let perApp = stats(input, .allTime).perApp
            XCTAssertEqual(perApp.first { $0.appBundleID == "com.a" }?.appName, "NewName")
        }
    }

    // MARK: - Daily trend

    func testDailyTrendBucketsAndWindow() {
        let recs = [
            snap(daysAgo: 0, words: 10, dur: 6, bundle: "com.a", name: "Alpha"),
            snap(daysAgo: 1, words: 20, dur: 12, bundle: "com.a", name: "Alpha"),
            snap(daysAgo: 1, words: 5, dur: 3, bundle: "com.b", name: "Beta"),
            snap(daysAgo: 5, words: 7, dur: 4, bundle: "com.a", name: "Alpha"),
            snap(daysAgo: 40, words: 99, dur: 30, bundle: "com.a", name: "Alpha"),
        ]
        let trend = stats(recs, .allTime).dailyTrend
        XCTAssertEqual(trend.count, 30)
        // Oldest → newest.
        XCTAssertEqual(trend, trend.sorted { $0.date < $1.date })
        XCTAssertEqual(trend.last?.words, 10)              // today
        XCTAssertEqual(trend[trend.count - 2].words, 25)   // yesterday: 20 + 5
        XCTAssertEqual(trend[trend.count - 6].words, 7)    // 5 days ago
        // The 40-day-old record is outside the 30-day window.
        XCTAssertEqual(trend.reduce(0) { $0 + $1.words }, 42)
    }

    // MARK: - Empty input

    func testEmptyHistory() {
        let s = stats([], .allTime)
        XCTAssertEqual(s.totalWords, 0)
        XCTAssertEqual(s.totalSessions, 0)
        XCTAssertEqual(s.totalDurationSeconds, 0)
        XCTAssertNil(s.aggregateWPM)
        XCTAssertNil(s.averageWordsPerSession)
        XCTAssertNil(s.averageSessionDuration)
        XCTAssertEqual(s.longestSessionWords, 0)
        XCTAssertTrue(s.perApp.isEmpty)
        XCTAssertNil(s.firstDictationDate)
        XCTAssertNil(s.mostUsedAppByWords)
        XCTAssertEqual(s.dailyTrend.count, 30)
        XCTAssertEqual(s.dailyTrend.reduce(0) { $0 + $1.words }, 0)
    }

    // MARK: - Shared word-count definition

    func testWordCountMatchesStreamingDefinition() {
        let cases = [
            "", "   ", "hello", "hello world", "  hello   world  ",
            "a\tb\nc", "\n\t  \n", "one two  three\tfour\nfive",
            "trailing ", " leading", "multiple\n\nnewlines",
        ]
        for input in cases {
            XCTAssertEqual(
                WordCount.count(input),
                StreamingTranscriber.words(input).count,
                "count/words disagree for \(input.debugDescription)")
            XCTAssertEqual(
                WordCount.words(input),
                StreamingTranscriber.words(input),
                "word split disagrees for \(input.debugDescription)")
        }
    }
}
