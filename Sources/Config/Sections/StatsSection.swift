import AppKit
import SwiftUI
import SwiftData
#if canImport(Charts)
import Charts
#endif

/// Usage statistics derived from dictation history: headline totals, a
/// per-application breakdown, and a recent-activity chart, scoped by a period
/// picker. Reads the same `@Query`'d `Transcription` records as `HistorySection`
/// and folds them through the pure `DictationStats` aggregator.
struct StatsSection: View {
    @Query(sort: \Transcription.timestamp, order: .reverse) private var items: [Transcription]
    @State private var period: StatPeriod = .allTime

    private var stats: DictationStats {
        let snapshots = items.map(\.statsSnapshot)
        return DictationStats.compute(from: snapshots, now: Date(), period: period)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No stats yet",
                    systemImage: "chart.bar",
                    description: Text("Record a few dictations and your usage stats will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                statsContent
            }
        }
        .navigationTitle("Stats")
    }

    private var statsContent: some View {
        // Compute the aggregate once per render — a single `Date()`, so every card
        // agrees on "now" — then thread it into the subviews instead of letting
        // each one recompute it.
        let stats = self.stats
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Period", selection: $period) {
                    ForEach(StatPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                headlineCards(stats)
                detailsCard(stats)
                perAppCard(stats)
                trendCard(stats)
            }
            .padding(20)
            .animation(.smooth(duration: 0.2), value: period)
        }
    }

    // MARK: - Headline cards

    private func headlineCards(_ stats: DictationStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            StatCard(title: "Words", symbol: "text.word.spacing",
                     value: stats.totalWords.formatted(), caption: period.title)
            StatCard(title: "Words / Min", symbol: "speedometer",
                     value: Self.wpm(stats.aggregateWPM), caption: "aggregate")
            StatCard(title: "Time", symbol: "clock",
                     value: Self.duration(stats.totalDurationSeconds), caption: "dictating")
            StatCard(title: "Dictations", symbol: "waveform",
                     value: stats.totalSessions.formatted(), caption: period.title)
        }
    }

    // MARK: - Details

    private func detailsCard(_ stats: DictationStats) -> some View {
        GroupBox {
            VStack(spacing: 10) {
                detailRow("Avg words / dictation", Self.decimal(stats.averageWordsPerSession))
                detailRow("Avg dictation length", Self.duration(stats.averageSessionDuration ?? 0))
                detailRow("Avg words / min (per session)", Self.wpm(stats.averageSessionWPM))
                detailRow("Longest dictation", "\(stats.longestSessionWords.formatted()) words")
                detailRow("Longest hold", Self.duration(stats.longestSessionDuration))
                detailRow("Characters dictated", stats.totalCharacters.formatted())
                if let top = stats.mostUsedAppByWords {
                    detailRow("Most-used app", top.appName)
                }
                if let first = stats.firstDictationDate {
                    detailRow("First dictation", first.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .padding(4)
        } label: {
            Label("Details", systemImage: "list.bullet")
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).foregroundStyle(.primary).monospacedDigit()
        }
    }

    // MARK: - Per-application table

    private func perAppCard(_ stats: DictationStats) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                perAppHeader
                Divider().padding(.vertical, 6)
                ForEach(Array(stats.perApp.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().padding(.vertical, 4) }
                    perAppRow(app)
                }
                if stats.perApp.isEmpty {
                    Text("No dictations in this period.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
            .padding(4)
        } label: {
            Label("By Application", systemImage: "app.badge")
        }
    }

    private var perAppHeader: some View {
        HStack(spacing: 12) {
            Text("Application")
            Spacer(minLength: 12)
            Text("Words").frame(width: 64, alignment: .trailing)
            Text("Sessions").frame(width: 64, alignment: .trailing)
            Text("WPM").frame(width: 52, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func perAppRow(_ app: AppStat) -> some View {
        HStack(spacing: 12) {
            Self.icon(for: app)
                .resizable().frame(width: 18, height: 18)
            Text(app.appName)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(app.isUnknown ? .secondary : .primary)
            Spacer(minLength: 12)
            Text(app.words.formatted())
                .frame(width: 64, alignment: .trailing).monospacedDigit()
            Text(app.sessions.formatted())
                .frame(width: 64, alignment: .trailing).monospacedDigit()
            Text(Self.wpm(app.wpm))
                .frame(width: 52, alignment: .trailing).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: - Trend

    @ViewBuilder private func trendCard(_ stats: DictationStats) -> some View {
        #if canImport(Charts)
        if stats.dailyTrend.contains(where: { $0.words > 0 }) {
            GroupBox {
                Chart(stats.dailyTrend) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Words", day.words)
                    )
                    .foregroundStyle(.tint)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 150)
                .padding(.top, 4)
            } label: {
                Label("Last 30 Days", systemImage: "calendar")
            }
        }
        #endif
    }

    // MARK: - Formatting

    private static func wpm(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    private static func decimal(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    /// "1h 23m" / "2m 5s" / "45s" / "—" for non-positive.
    private static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Generic glyph for the Unknown bucket / unresolvable bundle ids.
    private static let unknownIcon = Image(systemName: "questionmark.app.dashed")

    /// Memoized bundle-id → icon map. The resolve hits the disk (urlForApplication
    /// + icon(forFile:)), so cache it: the per-app table redraws on every render
    /// and period change. MainActor-isolated (StatsSection is), so the static is
    /// safe to mutate.
    private static var iconCache: [String: Image] = [:]

    /// The target app's Finder icon when resolvable, else the generic glyph.
    private static func icon(for app: AppStat) -> Image {
        guard let bundleID = app.appBundleID else { return unknownIcon }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return unknownIcon
        }
        let image = Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        iconCache[bundleID] = image
        return image
    }
}

/// A single headline metric tile.
private struct StatCard: View {
    let title: String
    let symbol: String
    let value: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
