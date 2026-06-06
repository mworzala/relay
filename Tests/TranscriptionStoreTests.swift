import XCTest
import SwiftData
@testable import Relay

/// Persistence guard for the `Transcription` SwiftData model. Writes rows to a
/// throwaway store, reopens it in a fresh `ModelContainer` (simulating a relaunch),
/// and confirms they load with the right values and stats-field defaults — the
/// model-level half of the "existing history migrates without crashing" criterion.
///
/// A faithful v1→v2 column-addition migration can't be reproduced in-process
/// without a versioned schema (which the plan deliberately avoids in favor of
/// SwiftData's automatic lightweight migration); that remains an interactive smoke
/// check. This still locks the contract that a row written the *pre-stats* way
/// (no app, no duration) round-trips and folds into stats as an Unknown-bucket row.
///
/// `nonisolated` class (matching the other suites under the project's
/// MainActor-by-default rule); the test method hops to `@MainActor` because
/// `ModelContext`/`mainContext` are main-actor isolated.
nonisolated final class TranscriptionStoreTests: XCTestCase {

    private func makeContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(url: url))
    }

    @MainActor
    func testRowsRoundTripThroughAReopenedStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("History.store")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedTimestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // --- Write with one container ---
        do {
            let container = try makeContainer(at: url)
            let context = container.mainContext
            // A "pre-stats" style row: text only, like the manual-add path — leaves
            // nil app / 0 duration, word count computed from text.
            context.insert(Transcription(text: "hello there world", timestamp: fixedTimestamp))
            // A full dictation row carrying all stats facts.
            context.insert(Transcription(
                text: "one two three four five",
                timestamp: fixedTimestamp.addingTimeInterval(60),
                appBundleID: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                durationSeconds: 12))
            try context.save()
        }

        // --- Reopen with a fresh container (relaunch) and read back ---
        let container = try makeContainer(at: url)
        let rows = try container.mainContext.fetch(
            FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.timestamp)]))

        XCTAssertEqual(rows.count, 2)

        let preStats = rows[0]
        XCTAssertEqual(preStats.text, "hello there world")
        XCTAssertNil(preStats.appBundleID)
        XCTAssertNil(preStats.appName)
        XCTAssertEqual(preStats.durationSeconds, 0)
        XCTAssertEqual(preStats.wordCount, 3)   // computed at insert from text

        let full = rows[1]
        XCTAssertEqual(full.appBundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(full.appName, "Slack")
        XCTAssertEqual(full.durationSeconds, 12)
        XCTAssertEqual(full.wordCount, 5)

        // --- Stats fold the loaded rows correctly ---
        // Use the same production mapping the stats UI uses (Transcription.statsSnapshot),
        // so this test exercises the real row→snapshot/migrated-count rule, not a copy.
        let snapshots = rows.map(\.statsSnapshot)
        let stats = DictationStats.compute(from: snapshots, now: fixedTimestamp.addingTimeInterval(120), period: .allTime)

        XCTAssertEqual(stats.totalWords, 8)        // both rows counted
        XCTAssertEqual(stats.totalSessions, 2)
        // The pre-stats row (nil app) lands in the Unknown bucket, last.
        XCTAssertTrue(stats.perApp.last?.isUnknown ?? false)
        XCTAssertEqual(stats.perApp.last?.words, 3)
        // The Slack row drives the (only) per-app WPM: 5 words / (12/60) min = 25.
        let slack = try XCTUnwrap(stats.perApp.first { $0.appBundleID == "com.tinyspeck.slackmacgap" })
        XCTAssertEqual(try XCTUnwrap(slack.wpm), 25, accuracy: 0.0001)
    }
}
