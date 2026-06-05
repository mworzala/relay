# Plan 5 — AXTextMarker support (sighted Chromium/Electron, direct typing mode)

> **For the implementing agent.** Self-contained task brief; you have no memory of
> the conversation that produced it. Read the referenced files before editing. This
> repo is **Relay**, a macOS 26 push-to-talk dictation app (Swift 6, Xcode 26
> MainActor-by-default isolation, XcodeGen from `project.yml`).
>
> **Read first:** [`docs/text-injection-research.md`](../text-injection-research.md)
> §2 (the verified AXTextMarker findings, with Chromium-source URLs) and §5 (open
> questions). Every API claim below is sourced there. Also read
> [`docs/ax-injection.md`](../ax-injection.md) for what we do today.

## Goal

Make Relay **sighted in Chromium/Electron**. Today, in a Slack/VS Code/Notion
contenteditable we effectively cannot read the caret/selection (offset
`kAXSelectedTextRange` is inert/frozen, `kAXValue` returns the placeholder) and we
place the caret with a synthetic `⌘A→→` keystroke hack. Adopt the **AXTextMarker /
AXTextMarkerRange** family — the node-anchored DOM-position API VoiceOver drives for
web content — to **read** the caret/selection/surrounding text and **place** the
caret precisely. This improves the **`.typeDirectly`** insertion mode in Electron
apps and lays the primitive foundation other work builds on.

This plan is the **canonical owner of the marker primitive layer** (new
`Sources/Injection/AXMarker.swift`). See **Parallel execution** below — Plan 7 and
the overlay anchor consume this primitive.

## What this nets us (and what it does NOT)

- **Reads (new capability):** the current selection and the text around the caret in
  Chromium — feeds `PrefixUnifier` spacing/caps/dedup, which today degrade in
  Electron because offset reads lie.
- **Caret placement:** set a collapsed selection at any DOM position via a *real*
  `kSetSelection` (no DOM rebuild, no caret collapse) — replaces the end-only,
  timing-raced `SyntheticKeys.moveCaretToEnd()` (`⌘A→→`) hack and allows mid-field
  positioning.
- **Does NOT give us AX text *replacement* in Chromium** — that op is behind a
  disabled-by-default Chrome flag and WebKit's replace API is Safari-only (research
  §2). Insertion still goes through the existing `kAXValue` write (and/or paste); the
  marker layer only **reads** and **positions/selects**.

## Architecture you're extending

- [`Sources/Injection/AXText.swift`](../../Sources/Injection/AXText.swift) — offset
  (UTF-16) AX primitives. The marker layer is a **sibling**, not a replacement;
  native Cocoa fields keep using offsets.
- [`Sources/Injection/AXTextInjector.swift`](../../Sources/Injection/AXTextInjector.swift) —
  the AX direct strategy. Value-write path + the `⌘A→→` caret repair
  (`final, writeMode == .value`) live here.
- [`Sources/Injection/InjectionCoordinator.swift`](../../Sources/Injection/InjectionCoordinator.swift) —
  `beginAX` captures the caret prefix/next-char via offset `AXText.string`; add a
  marker read path for web content.
- [`Sources/Probe/main.swift`](../../Sources/Probe/main.swift) — `ax-dump`
  subcommand; extend with marker support reporting.

## Design

### 1. `Sources/Injection/AXMarker.swift` — the primitive layer (`nonisolated`)

Wrap the marker attributes by **raw CFString name** (they are private/undeclared in
the public SDK; the names live in Chromium/WebKit/AppKit — research §2). Mirror
`AXText`'s style: `nonisolated enum`, off-main, UTF-16-agnostic (markers are opaque
DOM positions, not offsets). Implement:

- **Constants:** `AXSelectedTextMarkerRange`, `AXStartTextMarker`, `AXEndTextMarker`,
  `AXStringForTextMarkerRange`, `AXBoundsForTextMarkerRange`, `AXTextMarkerForIndex`,
  `AXIndexForTextMarker`, `AXTextMarkerRangeForUnorderedTextMarkers`,
  `AXLengthForTextMarkerRange`.
- **Capability probe** `supportsTextMarkers(_ element) -> Bool` — does the element
  expose `AXSelectedTextMarkerRange` (advertised attribute)? Gate all marker use on
  this; non-web elements fall through to the existing offset path.
- **Reads:** `selectedRange(of:) -> AXValue?` (the marker range, GET),
  `string(of:in range:) -> String?` (`AXStringForTextMarkerRange`),
  `bounds(of:for range:) -> CGRect?` (`AXBoundsForTextMarkerRange`, **screen rect**),
  `index(of:for marker:) -> Int?` and `marker(of:forIndex:) -> AXValue?`.
- **Set-selection / caret placement** `setSelection(of:_ range:) -> Bool` — write
  `AXSelectedTextMarkerRange`.
- **Range construction WITHOUT the private create API.** The opaque
  `AXTextMarkerRangeCreate` is undocumented/unlocated (research §5 #8). **Avoid it:**
  build a degenerate range from a single index via the parameterized attributes
  Chromium *does* implement — `AXTextMarkerForIndex(N)` → an array `[m, m]` →
  `AXTextMarkerRangeForUnorderedTextMarkers` → a range. Provide
  `collapsedRange(of:atIndex:) -> AXValue?` composing these. (For the read direction,
  the macOS-12+ public `AXTextMarkerRangeCopyStartMarker`/`…CopyEndMarker` accessors
  exist if you need to decompose a range.)
- Markers are opaque `CFTypeRef`/`AXValue`-bridged handles; treat them as opaque,
  pass them straight back to the AX C API. Set the per-message timeout
  (`AXText.setTimeout`) on the element first.

### 2. Direct-mode caret placement in `AXTextInjector`

In `apply(...)`, when `AXMarker.supportsTextMarkers(element)` (Chromium/Electron):

- **Replace the `⌘A→→` caret repair.** Today: `final, writeMode == .value` →
  `queue.asyncAfter(0.15) { SyntheticKeys.moveCaretToEnd() }`. Instead, after the
  value write settles, place the caret with
  `AXMarker.setSelection(element, AXMarker.collapsedRange(of: element, atIndex: end))`
  where `end = insertionStart + target.utf16.count`. This is deterministic,
  mid-field-capable, and avoids the select-all flash. **Keep `moveCaretToEnd()` as
  the fallback** when the marker set fails or the element isn't web content.
- Gate on `State::kEditable` being reported (the setter is a no-op otherwise —
  research §2). Keep the existing offset `setSelectedRange` for native fields.

> This **subsumes** the "switch the caret repair to AXSelectedTextMarkerRange" item
> from the Tier-1 plan (Plan 7) — see Parallel execution. The repair lives in
> direct-mode `AXTextInjector`, so it is owned here.

### 3. Marker-based context reads in `InjectionCoordinator.beginAX`

`readPrefix`/`readNextChar` use offset `AXText.string`, which lies in Chromium. When
`AXMarker.supportsTextMarkers`, read the prefix/next-char around the caret via the
marker range instead (get the selection range start marker, walk back a bounded
window via `AXTextMarkerForIndex`/`AXStringForTextMarkerRange`). Fall back to the
offset reads when markers are unavailable. Goal: `PrefixUnifier` spacing/caps/dedup
works in Electron.

### 4. Probe

Extend `relay-asr-probe ax-dump` (or add `marker-dump`) to print, for the focused
element: `supportsTextMarkers`, the selected marker range's string + bounds, and
whether set-selection round-trips. Headless per-app marker-support survey. Add
`AXMarker.swift` to the `relay-asr-probe` target sources in `project.yml`.

### 5. Robustness / gating

- **Capability-gated:** only use markers when `supportsTextMarkers` is true; always
  keep the offset path as fallback. Native fields are unaffected.
- **Migration-flag risk (research §2):** the Chromium setter is reachable today only
  because the attribute isn't yet migrated behind `kMacAccessibilityAPIMigration`.
  Treat a failed set as "fall back," never fatal; don't assume it across Chrome
  versions.
- **Lazy tree:** markers can be empty until the AX tree builds (after the manual-AX
  flip). Don't treat an empty first read as failure.
- **Caret-survival is inferred, not benchmarked (research §5 #2).** The Verification
  step must check it on real apps before we trust it over the keystroke path.

## Parallel execution & file ownership

Implemented on a worktree in parallel with Plan 6 (IMK, independent) and Plan 7
(Tier-1 hardening, **overlaps this plan**).

- **This plan OWNS:** `Sources/Injection/AXMarker.swift` (new), the **caret-placement
  path** in `AXTextInjector.apply` (direct mode), and the **marker context reads** in
  `InjectionCoordinator.beginAX`.
- **Shared files also edited by Plan 7:** `AXTextInjector.swift` (Plan 7 edits the
  *success-oracle / verify* region — a different function region than our caret path)
  and `InjectionCoordinator.swift` (Plan 7 edits the *manual-AX flip retry* in
  `startSession` — different region than our `beginAX` reads). Keep edits surgical
  and localized to ease the merge.
- **Plan 7 consumes** `AXMarker.boundsForRange`/`setSelection` for its overlay anchor
  and (nominally) caret repair. **Recommended merge order: Plan 5 → Plan 7.** If Plan
  7 lands first, it must define the minimal `AXMarker` functions with the **exact
  signatures in §1** so this plan's fuller version merges as a superset.

## Files

**New**
- `Sources/Injection/AXMarker.swift` — marker primitive layer.

**Changed**
- `Sources/Injection/AXTextInjector.swift` — marker caret placement (direct mode).
- `Sources/Injection/InjectionCoordinator.swift` — marker context reads in `beginAX`.
- `Sources/Probe/main.swift` — marker dump in the probe.
- `project.yml` — add `AXMarker.swift` to the `relay-asr-probe` target.
- (Tests) — any pure index/range bookkeeping helpers.

## Verification

- **Unit** (`RelayTests`, `nonisolated`): pure helpers only (live marker behavior is
  TCC-gated). E.g. any index↔window math you factor out.
- **Probe (headless):** `relay-asr-probe marker-dump` against the focused element in
  TextEdit (native), Safari, **Slack**, **VS Code**, **Discord**, **Claude** — record
  `supportsTextMarkers`, selection string, bounds, set-selection round-trip.
- **Interactive (TCC-gated):** with Accessibility granted, dictate in `.typeDirectly`
  mode into Slack/VS Code/Discord and confirm: caret lands at the end of the inserted
  text (and mid-field) **without** the `⌘A→→` flash; spacing/caps against existing
  text is correct (marker prefix read); native fields unchanged.
- **Caret-survival check (the inferred risk):** type into a contenteditable, then
  cause a DOM mutation; confirm the marker-set caret holds better than the offset
  write did. If it does NOT, keep the keystroke fallback as default and document.
- `make build` clean; `make test` green.

## Acceptance criteria

- [ ] `AXMarker.swift` provides capability probe, reads (selection/string/bounds),
      set-selection, and degenerate-range construction **without** the private create
      API (uses `AXTextMarkerRangeForUnorderedTextMarkers`).
- [ ] In `.typeDirectly` mode, Chromium/Electron caret placement uses marker
      set-selection (gated on `kEditable`/capability), with the `⌘A→→` keystroke as
      fallback.
- [ ] Caret-prefix/next-char reads use markers in web content so `PrefixUnifier`
      works there; offset path preserved for native fields.
- [ ] Probe reports per-app marker support.
- [ ] Native-field behavior is unchanged; everything is capability-gated with the
      offset path as fallback.
- [ ] Builds + unit tests pass.

## Commit strategy

1. `AXMarker.swift` primitive + probe `marker-dump` (read-only; no behavior change).
2. Marker caret placement in `AXTextInjector` (gated, fallback preserved).
3. Marker context reads in `InjectionCoordinator.beginAX`.
4. Tests + docs note in `ax-injection.md`.

## Out of scope

- AX **range replacement** in Chromium (flag-disabled — research §2). Insertion stays
  on the existing value-write/paste paths.
- Overlay caret anchoring via `AXBoundsForTextMarkerRange` — **Plan 7** (overlay-paste
  mode, different file `CaretLocator.swift`).
- The IMK path — **Plan 6**.
