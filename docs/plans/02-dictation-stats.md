# Plan 2 — Dictation statistics (collected at history-record time)

> **For the implementing agent.** Self-contained task brief; you have no memory of
> the conversation that produced it. Read the referenced files before editing. This
> repo is **Relay**, a macOS 26 push-to-talk dictation app (Swift 6, Xcode 26
> MainActor-by-default isolation, XcodeGen from `project.yml`, SwiftData for
> history).

## Goal

Collect and surface usage statistics derived from each finalized dictation, at the
moment it is recorded into history. Required stats: **total words** (overall and
**broken down by application**) and **words per minute**. Add a curated set of
additional stats (see §"Stat catalog"). Expose them in a new **Stats** section of
the configuration window.

## Why / where the data is born

Every finished dictation is saved via
[`HistoryStore.add(_:)`](../../Sources/History/HistoryStore.swift), called from
[`DictationController.finish()`](../../Sources/App/DictationController.swift) on
key-up. Today a saved record is just `{ id, text, timestamp }`
([`Sources/History/Transcription.swift`](../../Sources/History/Transcription.swift)).
To compute per-app totals and WPM we must capture **two more facts at save time**:
the **target application** and the **dictation duration**. Both are available in the
controller at `finish()` time but are currently dropped.

## Current state you're extending

- [`Sources/History/Transcription.swift`](../../Sources/History/Transcription.swift) —
  SwiftData `@Model` with `id`, `text`, `timestamp`.
- [`Sources/History/HistoryStore.swift`](../../Sources/History/HistoryStore.swift) —
  `@MainActor enum`; `add(_ text:timestamp:)` inserts + saves; owns the
  `ModelContainer` (pinned to `AppPaths.historyStore`).
- [`Sources/App/DictationController.swift`](../../Sources/App/DictationController.swift) —
  `beginDictation()` starts a session; `finish()` builds `finalText`, calls
  `HistoryStore.add(finalText)`. **Session timing**: a start timestamp is taken
  in the overlay (`OverlayController.show()` sets `startDate`) and `elapsed` is
  tracked there, but the controller itself does not currently retain the start
  time — add one in `beginDictation()` so duration is authoritative and independent
  of the overlay.
- [`Sources/Config/ConfigView.swift`](../../Sources/Config/ConfigView.swift) —
  `enum ConfigSection` (microphone, shortcut, model, formatting, history, general)
  drives a sidebar + detail. Sections live in
  [`Sources/Config/Sections/`](../../Sources/Config/Sections).
- App identity API: `NSWorkspace.shared.frontmostApplication` →
  `bundleIdentifier`, `localizedName`. (If Plan 1 — AX injection — lands first, the
  resolved app identity is already available in the injection context; prefer
  reusing it. This plan must also stand alone without Plan 1.)

## Design

### 1. Extend the `Transcription` model

Add (all with defaults so SwiftData lightweight migration is automatic — adding
optional / defaulted properties does not require a manual migration plan):

```
var appBundleID: String?      // e.g. "com.tinyspeck.slackmacgap"; nil if unknown
var appName: String?          // localized, for display; nil if unknown
var durationSeconds: Double    // dictation hold duration; 0 if unknown
var wordCount: Int             // denormalized for cheap aggregation/queries
```

- `wordCount` is derivable from `text`, but storing it makes stats queries cheap and
  stable. Compute it once at insert using the **same word definition** as the ASR
  layer: whitespace/newline/tab split (mirror `StreamingTranscriber.words(_:)` in
  [`Sources/ASR/StreamingTranscriber.swift`](../../Sources/ASR/StreamingTranscriber.swift)
  — factor a shared `wordCount(_:)` helper so the definition can't drift).
- Keep `appBundleID`/`appName`/`durationSeconds` optional/zeroable so **existing
  history rows migrate cleanly** and are simply excluded from per-app/WPM math.

### 2. Capture app + duration at save time

- In `DictationController.beginDictation()`: record `sessionStart = Date()` (a
  stored `@ObservationIgnored var`). Also capture the **frontmost app at session
  start** (where the text will land) — `NSWorkspace.shared.frontmostApplication`.
  Capturing at *start* (not finish) is more correct: the pill never steals focus
  (`NonActivatingPanel`), and the user's target app is frontmost while they hold to
  talk. If Plan 1 is present, take the app from its `InjectionContext` instead.
- In `finish()`: compute `duration = Date().timeIntervalSince(sessionStart)` and
  pass app id/name + duration into the store.
- Extend `HistoryStore.add` to accept the new fields (keep a backward-compatible
  default-valued signature so the manual-add field in `HistorySection` still works):
  `add(_ text:timestamp:appBundleID:appName:durationSeconds:)`.
- The manual-add path in
  [`Sources/History/HistorySection.swift`](../../Sources/History/HistorySection.swift)
  inserts directly; leave its rows with nil app / 0 duration (they're test rows).

### 3. Stats aggregation (pure, testable)

Create `Sources/History/DictationStats.swift`:

- A `nonisolated struct DictationStats` plus a **pure** `static func compute(from:
  [TranscriptionSnapshot], now: Date, period: StatPeriod) -> DictationStats`.
- Use a small `Sendable` value snapshot (`TranscriptionSnapshot { timestamp,
  wordCount, durationSeconds, appBundleID, appName }`) extracted from the SwiftData
  models so the aggregator is pure, off-model, and unit-testable without a store.
- `StatPeriod`: `.today`, `.last7Days`, `.last30Days`, `.allTime` (filter by
  `timestamp`).
- **WPM rules** (be explicit to avoid nonsense): WPM = totalWords ÷ totalMinutes,
  where totalMinutes sums `durationSeconds` of records that have a duration > a
  small floor (e.g. ignore sessions < 0.5s to avoid divide-by-tiny inflation).
  Provide both an **aggregate WPM** (sum words ÷ sum minutes) and an **average of
  per-session WPM** if cheap — aggregate is the headline number. Records with
  unknown duration are excluded from WPM but still counted in word totals.
- **Per-app breakdown**: group by `appBundleID` (fallback bucket "Unknown" for nil),
  carry a display `appName`, sort by words desc. Each app row: words, sessions,
  total duration, WPM.

### Stat catalog

Required:
- Total words (all time + selected period).
- Total words per application.
- Words per minute (aggregate; per-app WPM in the breakdown).

Add these (cheap, genuinely useful):
- Total dictations (sessions) — overall and per app.
- Total dictation time (sum of durations) — "time spent dictating".
- Average words per session; average session duration.
- Longest dictation (by words and by duration).
- Daily trend: words per day over the last 30 days (for a small bar/sparkline).
- Most-used app (top by words) and by sessions.
- Busiest hour-of-day / day-of-week (optional, if you add the trend UI).
- Total characters typed (proxy for keystrokes saved) — a nice "value" metric.
- First-used date / streak (optional, low priority).

Keep the headline view focused; put the long tail in a secondary area or behind the
period picker.

### 4. Stats UI

- Add `case stats` to `ConfigSection` in `ConfigView.swift` (title "Stats", SF
  Symbol e.g. `chart.bar`), and route it to a new
  `Sources/Config/Sections/StatsSection.swift`.
- `StatsSection`:
  - `@Query` the `Transcription` records (reuse the existing `modelContainer`
    environment, same as `HistorySection`), map to snapshots, call
    `DictationStats.compute`.
  - A `StatPeriod` picker (segmented) at the top.
  - Headline cards: Total words, WPM, Total time, Sessions.
  - A per-application table/list (app name, words, sessions, WPM) sorted desc, with
    the "Unknown" bucket last.
  - Optional: a simple 30-day words-per-day bar chart (SwiftUI `Chart` from the
    `Charts` framework is available on macOS 26 — fine to use; keep it optional and
    degrade gracefully).
  - Empty state via `ContentUnavailableView` like `HistorySection` when there's no
    data.
- Performance: aggregation is in-memory over the full history. Thousands of rows is
  trivial. If history could be huge, compute on a background hop and cache; not
  required initially.

## Files

**New**
- `Sources/History/DictationStats.swift` — snapshots + pure aggregator + `StatPeriod`.
- `Sources/Config/Sections/StatsSection.swift` — the UI.
- `Tests/DictationStatsTests.swift` — aggregator unit tests.

**Changed**
- `Sources/History/Transcription.swift` — new fields (defaulted/optional).
- `Sources/History/HistoryStore.swift` — extended `add(...)`; shared `wordCount`.
- `Sources/App/DictationController.swift` — capture `sessionStart` + app, pass to store.
- `Sources/Config/ConfigView.swift` — new `stats` section + routing.
- Possibly `Sources/ASR/StreamingTranscriber.swift` — extract shared `wordCount`/
  `words` helper (or put the shared helper in a small new util and have both call it).

New `Sources/**` files are auto-globbed into the `Relay` target by XcodeGen. Run
`make generate` (or `make build`). Unit tests live in `Tests/` (the `RelayTests`
target globs `Tests`).

## Migration / compatibility

- Adding **optional or defaulted** SwiftData properties triggers automatic
  lightweight migration — no `SchemaMigrationPlan` needed. Verify by launching
  against an existing `History.store`: old rows must load with nil app / 0 duration
  and **not** crash. The container currently `fatalError`s on incompatible stores
  (`HistoryStore.container`), so test this explicitly with a pre-existing store.
- Do **not** rename/retype existing properties (that would force a heavy migration).
- Old rows (no duration/app) are excluded from WPM and land in the "Unknown" app
  bucket but still contribute to total words — make the aggregator handle this.

## Verification

- **Unit tests** (`RelayTests`; test classes `nonisolated` per MainActor-default
  rule — see `Tests/TextProcessingTests.swift`):
  - `DictationStats.compute` over hand-built snapshot fixtures: total words; per-app
    grouping incl. the Unknown bucket; WPM math incl. the < 0.5s floor and
    unknown-duration exclusion; period filtering (today/7d/30d/all) against a fixed
    `now`; averages and longest-session selection.
  - `wordCount` definition matches `StreamingTranscriber.words` for tricky inputs
    (multiple spaces, tabs/newlines, leading/trailing whitespace, empty string).
- **Build**: `make build` clean; `make test` green.
- **Interactive smoke** (optional): dictate a few phrases into two different apps,
  open Stats, confirm per-app split and a plausible WPM; confirm an old store still
  opens.

## Acceptance criteria

- [ ] Each newly recorded dictation stores target app (bundle id + name), duration,
      and word count, captured at save time.
- [ ] Existing history migrates without crashing; old rows count toward total words
      and sit in an "Unknown" app bucket, excluded from WPM.
- [ ] A new **Stats** config section shows total words, WPM, total time, and a
      per-application breakdown, with a period picker (today / 7d / 30d / all).
- [ ] WPM math is well-defined (floor on tiny sessions; unknown durations excluded)
      and unit-tested.
- [ ] Word-count definition is shared with the ASR layer (single source of truth).
- [ ] Builds and unit tests pass.

## Commit strategy

Land in **distinct, reviewable commits**, each building green (`make build` /
`make test`) before the next:

1. `Transcription` model fields + extended `HistoryStore.add` + shared `wordCount`
   helper, including the lightweight-migration check against an existing store.
2. Capture target app + duration in `DictationController` and thread them through
   the store.
3. `DictationStats` pure aggregator + unit tests.
4. `StatsSection` UI + `ConfigSection` wiring.

Use imperative, scoped commit messages.

## Notes / open questions for the requester

- **Duration semantics**: defined here as the hold-to-talk duration (start of
  `beginDictation` → `finish`), i.e. speaking time, which is the natural WPM
  denominator. If you'd rather measure wall-clock including the arm delay or
  trailing finalize, say so.
- **Privacy**: stats store an app bundle id per dictation (not which field, not
  surrounding text). If even per-app attribution is unwanted, we can make it
  opt-in. Default assumed: on.
- **Display home**: a dedicated Stats section is assumed. If you'd prefer the
  numbers inline in the History header instead, that's a small change.
