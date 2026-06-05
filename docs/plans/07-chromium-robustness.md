# Plan 7 — Tier-1 Chromium/Electron robustness hardening

> **For the implementing agent.** Self-contained task brief; you have no memory of
> the conversation that produced it. Read the referenced files before editing. This
> repo is **Relay**, a macOS 26 push-to-talk dictation app (Swift 6, Xcode 26
> MainActor-by-default isolation, XcodeGen from `project.yml`).
>
> **Read first:** [`docs/text-injection-research.md`](../text-injection-research.md)
> §2 (Wispr's v2.0.0 success-oracle fix, AX flags/lazy tree), §4 Tier-1, and the
> Espanso timing/sentinel references. Also [`docs/ax-injection.md`](../ax-injection.md).

## Goal

A bundle of **low-effort, high-payoff** robustness fixes for Chromium/Electron, drawn
from the research §4 Tier-1 list:

1. **Stop trusting AX value read-back as the insertion success oracle.** (`AXTextInjector`)
2. **Strengthen the manual-AX flip:** retry even when the flip's setter returns
   false, and settle/retry reads before trusting them; don't treat the setter return
   as fatal. (`InjectionCoordinator`)
3. **Anchor the overlay-paste caret via `AXBoundsForTextMarkerRange`** instead of the
   frozen offset bounds. (`CaretLocator`)
4. **Adopt Espanso's paste timings + a self-event sentinel.** (`PasteInjector`,
   `SyntheticKeys`)

> **Reassigned item:** the user's Tier-1 list also said "switch the caret repair to
> AXSelectedTextMarkerRange." That repair lives in **direct-mode** `AXTextInjector`
> and needs the marker primitive, so it is **owned by Plan 5**
> ([`05-axtextmarker.md`](05-axtextmarker.md) §2), not this plan. This plan does not
> touch the `AXTextInjector` caret path. (Flag the owner if you'd rather keep it here.)

## Architecture you're extending

- [`Sources/Injection/AXTextInjector.swift`](../../Sources/Injection/AXTextInjector.swift) —
  the AX strategy. The **success-oracle** logic is the `firstWrite` inert-detection in
  `apply(...)` (the `valueBefore` snapshot + `Self.changed(from:)` + the
  "selectedText inert → switch to value" branch).
- [`Sources/Injection/InjectionCoordinator.swift`](../../Sources/Injection/InjectionCoordinator.swift) —
  `startSession` does the `enableManualAccessibility` flip + the bounded re-probe
  loop (`manualAXProbeAttempts`). `AXText.enableManualAccessibility` already sets
  **both** `AXManualAccessibility` and `AXEnhancedUserInterface`.
- [`Sources/Overlay/CaretLocator.swift`](../../Sources/Overlay/CaretLocator.swift) —
  the caret-rect fallback ladder; `caretRect(of:)` uses
  `kAXBoundsForRangeParameterizedAttribute` (offset, frozen in Chromium).
- [`Sources/Injection/PasteInjector.swift`](../../Sources/Injection/PasteInjector.swift) —
  the overlay-paste finalize: `Clipboard.setStringForPaste` → `SyntheticKeys.paste()`
  (⌘V) → wait `restoreDelay` (0.5s) → conditional restore.
- [`Sources/Injection/SyntheticKeys.swift`](../../Sources/Injection/SyntheticKeys.swift) —
  posts CGEvent chords (`post`, `paste`, `moveCaretToEnd`).
- [`Sources/Hotkey/HotkeyMonitor.swift`](../../Sources/Hotkey/HotkeyMonitor.swift) —
  **passive** `NSEvent` global/local monitors (not a CGEventTap). They *do* receive
  synthetic events; the key matcher filters by the hold-to-talk key, so there's no
  misfire today — but the sentinel (§4) makes that robust for future key-watching.

## Design

### 1. Stop trusting value read-back as the success oracle (`AXTextInjector`)

Per research §2, Electron apps "don't report back the text currently in the input
field," so comparing `kAXValue`/`kAXNumberOfCharacters` before/after treats successful
inserts as failures (the exact bug Wispr fixed in v2.0.0). We already partially trust
value-writes; tighten the rest:

- The **only** failure signal that triggers the keystroke fallback should be a **real
  AX API error** (`AXUIElementSetAttributeValue` returned non-`.success`) — never "the
  read-back value didn't change." Keep using the content read **only** to *choose*
  between `selectedText` and `value` mode on the first write, never as the
  success/fail oracle after a value write (today's code already does this for value —
  audit `apply(...)` and remove/neutralize any remaining value-read-back-as-success
  logic, and document the invariant in a comment).
- Add an explicit **double-insertion guard**: track that a given target was already
  committed (we have `lastWritten`); ensure a retried render after a "looked inert but
  actually landed" write cannot double-insert (e.g. never re-issue the same target via
  a second mode after a successful-API value write).
- Note in `ax-injection.md` that read-back is not the oracle.

### 2. Strengthen the manual-AX flip + retry (`InjectionCoordinator.startSession`)

`AXText.enableManualAccessibility` already sets **both** flags — good. Improvements:

- **Retry regardless of the flip's boolean.** Today the re-probe loop runs only
  `if flipped`. Electron historically did **not** advertise `AXManualAccessibility`
  (returned unsupported) yet still built the tree once the keys were set (research §2,
  Electron PR #38102). So run the bounded re-resolve/re-probe loop **even when
  `enableManualAccessibility` returned false**, as long as we have a frontmost pid.
- **Settle before trusting the first read.** The tree builds asynchronously and the
  first walk can be empty (research §2). The existing loop already sleeps between
  attempts; ensure at least one settle (~200 ms cumulative is fine; the current
  8×50 ms window already covers this) before concluding "not usable." Don't shorten
  it below ~200 ms.
- Keep everything off-main on the coordinator queue (unchanged threading).

### 3. Overlay caret anchor via `AXBoundsForTextMarkerRange` (`CaretLocator`)

Add a **marker-bounds rung** to the fallback ladder, *before* the existing offset
`kAXBoundsForRangeParameterizedAttribute` rung: GET `AXSelectedTextMarkerRange`, take
its (collapsed) start, and read `AXBoundsForTextMarkerRange` → the real on-screen
caret rect in Chromium. Then the existing flip-to-AppKit conversion applies as today.

- **Dependency note (see Parallel execution):** the marker read belongs in Plan 5's
  `AXMarker.swift` (`AXMarker.selectedRange` + `AXMarker.bounds`). **Prefer calling
  it.** If Plan 5 hasn't landed on your worktree, inline a *minimal, self-contained*
  reader in `CaretLocator` using the raw CFString attribute names (so this plan builds
  standalone), and leave a `// TODO: consolidate with AXMarker (Plan 5)` marker.
- Keep the offset-bounds rung and the element-frame/mouse rungs as fallbacks; only
  insert marker-bounds as the new top rung, gated on the element advertising
  `AXSelectedTextMarkerRange`.

### 4. Espanso paste timings + self-event sentinel (`PasteInjector`, `SyntheticKeys`)

Per research §4 (Espanso's shipped values):

- **Pre-paste settle:** in `PasteInjector.run`, after `Clipboard.setStringForPaste`,
  wait ~**100 ms** before posting ⌘V so the pasteboard write is reliably visible to
  the target before the paste reads it.
- **Restore delay:** Espanso uses ~300 ms; we currently use 0.5 s (conservative).
  Keep a single tuned constant; you may lower toward ~300 ms **only** if the
  Verification paste tests stay reliable on a slow Electron target — otherwise leave
  0.5 s. Keep the `changeCount`-guard restore (don't clobber a fresh user copy).
- **Self-event sentinel:** stamp every synthetic CGEvent Relay posts with a sentinel
  so input observers can identify Relay's own events. In `SyntheticKeys.post`, set a
  recognizable field on both the down and up events — e.g.
  `event.setIntegerValueField(.eventSourceUserData, RelaySyntheticEvent.sentinel)` (a
  fixed magic constant) — and expose a helper `isRelaySynthetic(_ CGEvent) -> Bool`.
  In `HotkeyMonitor.handle`, **ignore events whose `cgEvent` carries the sentinel** so
  Relay never reacts to its own ⌘V / caret keystrokes (defensive; required if a future
  feature watches keys via a tap). Document that this is best-effort (some event paths
  drop user-data fields).

## Parallel execution & file ownership

Implemented on a worktree in parallel with Plan 5 (AXTextMarker — **overlaps**) and
Plan 6 (IMK — independent).

- **This plan OWNS exclusively:** `CaretLocator.swift`, `PasteInjector.swift`,
  `SyntheticKeys.swift`, `HotkeyMonitor.swift`.
- **Shared with Plan 5:**
  - `AXTextInjector.swift` — this plan edits the **success-oracle / verify** region of
    `apply(...)`; Plan 5 edits the **caret-placement** region of the same function.
    Different regions — keep edits localized; expect a small, resolvable merge.
  - `InjectionCoordinator.swift` — this plan edits `startSession` (flip retry); Plan 5
    edits `beginAX` (marker reads). Different functions — clean.
  - `AXMarker.swift` (Plan 5-owned) — this plan *consumes* `selectedRange`/`bounds`
    for §3. Do **not** redefine it; call it, or inline a temporary minimal reader in
    `CaretLocator` if Plan 5 hasn't landed.
- **Recommended merge order: Plan 5 → Plan 7** (so §3 calls the real `AXMarker`).

## Files

**Changed**
- `Sources/Injection/AXTextInjector.swift` — success-oracle invariant (verify region).
- `Sources/Injection/InjectionCoordinator.swift` — flip-retry regardless of setter
  return; settle.
- `Sources/Overlay/CaretLocator.swift` — marker-bounds caret rung.
- `Sources/Injection/PasteInjector.swift` — pre-paste settle + tuned restore.
- `Sources/Injection/SyntheticKeys.swift` — sentinel stamp + `isRelaySynthetic`.
- `Sources/Hotkey/HotkeyMonitor.swift` — ignore sentinel-stamped events.
- (Docs) `docs/ax-injection.md` — note the read-back-is-not-the-oracle invariant.

## Edge cases & risks

- **Success oracle:** the risk is the *opposite* failure — a genuinely failed write
  that the API reported as `.success`. Mitigate with the double-insert guard and keep
  the keystroke fallback only for real API errors. Per Wispr, accept occasional silent
  no-ops over false-fallback double-inserts.
- **Flip retry without a real signal** could waste the bounded window on apps that
  truly have no text element — keep the window bounded (≤ ~400 ms) and the keystroke
  fallback intact.
- **Marker-bounds rung** must be capability-gated (element advertises the attribute)
  and must not regress native fields — keep the offset rung beneath it.
- **Pre-paste 100 ms** adds latency to every overlay-paste finalize — acceptable
  (it's after release), but don't stack it redundantly with the restore delay.
- **Sentinel** is best-effort; never rely on it for correctness, only as a guard.

## Verification

- **Unit** (`RelayTests`, `nonisolated`): the sentinel round-trip
  (`isRelaySynthetic` on a stamped CGEvent), and any pure timing/constant helpers.
- **Interactive (TCC-gated):**
  - Dictate (direct mode) repeatedly into **Slack/Claude/Discord**; confirm no
    false-fallback double-insertions and no spurious keystroke fallback when the AX
    value write actually landed.
  - First dictation into a **cold** Electron app resolves to AX (flip-retry) more
    often than before, instead of falling straight to keystrokes.
  - Overlay-paste mode in **Slack/VS Code**: the transcript box anchors at the real
    caret (marker bounds), not bottom-center.
  - Overlay-paste round-trip: text pastes at the caret, clipboard restored, no
    clobber of a fresh user copy; pre-paste settle doesn't lose the paste on a slow
    target.
  - The hotkey never misfires from Relay's own ⌘V / caret keystrokes.
- `make build` clean; `make test` green.

## Acceptance criteria

- [ ] Insertion success is judged by the AX API result (+ double-insert guard), never
      by `kAXValue`/`kAXNumberOfCharacters` read-back; documented invariant.
- [ ] The manual-AX re-probe runs even when the flip setter returns false, with a
      ≥~200 ms settle, and resolves more cold-Electron sessions to AX.
- [ ] Overlay caret anchors via `AXBoundsForTextMarkerRange` in Chromium, offset/
      element/mouse rungs preserved beneath it.
- [ ] Pre-paste ~100 ms settle + tuned restore; clipboard still safely restored and
      never clobbers a fresh copy.
- [ ] Synthetic events carry a sentinel; `HotkeyMonitor` ignores them.
- [ ] Native-field behavior unchanged; builds + unit tests pass.

## Commit strategy

1. Success-oracle invariant + double-insert guard (`AXTextInjector`) + doc note.
2. Flip-retry strengthening (`InjectionCoordinator`).
3. Marker-bounds caret rung (`CaretLocator`).
4. Espanso paste timings (`PasteInjector`).
5. Self-event sentinel (`SyntheticKeys` + `HotkeyMonitor`) + unit test.

## Out of scope

- Direct-mode caret repair via marker set-selection — **Plan 5**.
- The `AXMarker` primitive itself — **Plan 5** owns it; consume, don't redefine.
- IMK — **Plan 6**.
