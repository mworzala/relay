# Plan 3 — Caret-anchored "finalizing" overlay (optional feature)

> **For the implementing agent.** Self-contained task brief; you have no memory of
> the conversation that produced it. Read the referenced files before editing. This
> repo is **Relay**, a macOS 26 push-to-talk dictation app (Swift 6, Xcode 26
> MainActor-by-default isolation, XcodeGen from `project.yml`).
>
> **Dependency:** this builds on the Accessibility layer from
> [`01-ax-injection.md`](01-ax-injection.md). If Plan 1 has landed, reuse its
> `AXText` helper and the focused-element/selection plumbing. If Plan 1 has **not**
> landed, this plan includes the minimal AX caret-rect helper it needs (see §2) so
> it can ship independently — but prefer doing Plan 1 first.

## Goal

Add an **optional, default-off** feature: when a dictation ends, show a small
activity indicator **anchored at the text caret** while the app finishes the
authoritative ASR pass and post-processing, then dismiss it when the final text is
injected. Where the caret can't be located, fall back gracefully (element frame →
mouse → the existing bottom-center pill placement). This is purely a UI affordance;
it changes no transcription behavior.

## Why (background)

There is a real latency window at the end of a dictation that the user currently
gets no feedback for. In [`DictationController.finish()`](../../Sources/App/DictationController.swift)
the app runs an async authoritative full-buffer pass
(`streaming.finish()` → `AsrManager.transcribe(...)`, async; rtfx ~37, so a
10-second utterance ≈ ~270 ms, sometimes more) and then post-processing, before the
final reconcile. A tiny "finalizing…" indicator at the caret tells the user "your
words are landing here, hold on." It also becomes more valuable later if an async
post-processing stage is ever added (e.g. an LLM rewrite) — design it to cover that
window too.

> **Reality check:** today's post-processing
> ([`TranscriptPostProcessor`](../../Sources/TextProcessing/TranscriptPostProcessor.swift):
> ITN + regex replacements) is **synchronous and effectively instant**. The
> meaningful wait is the **final ASR pass**. So the indicator's lifetime should
> span `finish()` (from `phase = .finishing` until the final inject completes), not
> just "post-processing". Keep the trigger generic so a future async stage extends
> it for free.

## How the OS exposes the caret location

macOS does **not** have a "where is the text caret" system call; you get it through
the Accessibility API on the focused element:

1. Focused element: `kAXFocusedUIElementAttribute` on the system-wide element
   (already read by `AXFocus.focusedElement()` in
   [`Sources/Injection/TextInjector.swift`](../../Sources/Injection/TextInjector.swift)).
2. Caret as a zero-length range: `kAXSelectedTextRangeAttribute` →
   `CFRange(location: caret, length: 0)`.
3. **`kAXBoundsForRangeParameterizedAttribute`** with that range
   (`AXUIElementCopyParameterizedAttributeValue`) → an `AXValue` of type
   `kAXValueCGRectType` → `AXValueGetValue(_, .cgRect, &rect)`. For a zero-length
   range this is a thin rectangle sitting exactly at the I-beam, in **screen
   coordinates**.

**Coordinate gotcha:** AX rects use a **top-left origin** (flipped vs AppKit's
bottom-left `NSScreen` space). Convert before placing an `NSWindow`, accounting for
multiple displays — e.g. flip against the primary screen
(`NSScreen.screens.first { $0.frame.origin == .zero }`) height:
`appKitY = primary.frame.height - axRect.origin.y - axRect.height`. Make this a
small pure helper and unit-test it with synthetic screen heights (see Verification).

## Design

### 1. Caret location with a graceful fallback ladder

Add a `caretRect()` capability (in `AXText` if Plan 1 exists, else a small new
`Sources/Overlay/CaretLocator.swift`). Return the best available anchor as an
AppKit-space `NSRect?`, trying in order:

1. **Caret rect** via `kAXBoundsForRangeParameterizedAttribute` (best).
2. **Focused element frame** — `kAXPositionAttribute` (CGPoint) + `kAXSizeAttribute`
   (CGSize), anchor near its lower-left/baseline. (Some apps expose `"AXFrame"`
   directly.)
3. **Mouse location** (`NSEvent.mouseLocation`) — already AppKit space.
4. **nil** → caller falls back to the existing bottom-center pill placement.

Guards (mirror Plan 1): set `AXUIElementSetMessagingTimeout` so a hung target app
can't block; if `IsSecureEventInputEnabled()` or the element exposes no usable text
geometry, skip to the next rung. Convert AX rects (rungs 1–2) to AppKit space.

**Threading:** perform the AX query on the serialized off-main AX path (Plan 1's
injector queue, or a dedicated serial queue here) so it can't hang the main thread,
then publish the resolved `NSRect?` to the MainActor overlay via
`Task { @MainActor in ... }`. Respect the project's MainActor-default isolation
rules (off-main types `nonisolated` + `@unchecked Sendable`; hop to main for UI).

### 2. The indicator overlay

Reuse the existing overlay pattern rather than inventing one — see
[`Sources/Overlay/OverlayController.swift`](../../Sources/Overlay/OverlayController.swift)
and `NonActivatingPanel`:

- A borderless, **non-activating, click-through** (`ignoresMouseEvents = true`)
  `NSPanel` at `CGShieldingWindowLevel()` with
  `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, so it
  floats above everything (incl. full-screen apps) and never steals focus — exactly
  like the pill.
- Contents: a small, low-footprint activity view (a subtle pulsing dot or a tiny
  glass capsule with a `ProgressView`), **offset from the caret** so it doesn't
  occlude the text (e.g. a few px above-and-right of the caret rect). Keep it tiny.
- Position from the resolved caret rect; if `caretRect()` returns nil, either skip
  the caret indicator and let the normal bottom-center pill stand in, or show it
  bottom-center — pick one and be consistent.
- Lifecycle: shown when `finish()` enters `phase = .finishing`; hidden once the
  final text is injected (`injector.finalize` completed / `onSessionFinish`). Add a
  small minimum on-screen time + fade (reuse the pill's fade-in/out) so very fast
  finishes don't flicker. Fade-completion handlers run on main — use
  `MainActor.assumeIsolated` as `OverlayController` already does.

Decide whether this is a **second** controller (e.g. `CaretIndicatorController`) or
an extension of `OverlayController`. A separate small controller keeps the pill code
untouched and is cleaner; wire it from `AppModel` like the existing overlay.

### 3. Make it optional (default off)

- Add `var showFinalizingIndicator: Bool` to
  [`AppSettings`](../../Sources/Config/AppSettings.swift), default `false`. Add it
  to the private `Snapshot` as an **optional** (`Bool?`) decoded with `?? false`,
  mirroring the existing `enableITN` backward-compat pattern so older
  `settings.json` files still decode.
- Add a toggle in a config section — `GeneralSection`
  ([`Sources/Config/Sections/GeneralSection.swift`](../../Sources/Config/Sections/GeneralSection.swift))
  is the natural home (it's a UI/behavior preference), with a one-line explanation
  ("Show a small indicator at the text cursor while Relay finalizes a dictation").
  Call `settings.save()` on change, like the other settings controls.
- `DictationController` checks the flag before showing the indicator.

### 4. Debug tie-in (if Plan 1's diagnostics strip exists)

Have the caret locator report which rung it used (`caret` / `element-frame` /
`mouse` / `none`) as a field the Plan 1 diagnostics strip can display — handy for
seeing per-app caret support at a glance. Optional but cheap.

## Files

**New**
- `Sources/Overlay/CaretIndicatorController.swift` — the panel + lifecycle.
- Caret indicator SwiftUI view (new file or alongside the controller).
- `Sources/Overlay/CaretLocator.swift` — **only if Plan 1's `AXText` is absent**;
  otherwise add `caretRect(...)` to `AXText` and a pure coordinate-conversion
  helper.

**Changed**
- `Sources/Config/AppSettings.swift` — `showFinalizingIndicator` + Snapshot field.
- `Sources/Config/Sections/GeneralSection.swift` — the toggle.
- `Sources/App/DictationController.swift` — show on `.finishing`, hide after final
  inject, gated by the setting.
- `Sources/App/AppModel.swift` — construct + wire the indicator controller.
- (If Plan 1 present) `Sources/Injection/AXText.swift` — `caretRect` helper; and the
  diagnostics field in §4.

New `Sources/**` files are auto-globbed into the `Relay` target by XcodeGen. If you
add a caret helper the `relay-asr-probe` target should reach (for the probe
subcommand below), add its path explicitly under that target in `project.yml`, then
`make generate` (or `make build`).

## Edge cases & risks

- **Apps without caret bounds** (terminals, custom/Electron/web editors,
  Java/games): expect rung 2–4 fallbacks. Electron needs the `AXManualAccessibility`
  flip from Plan 1 and even then may only give an element frame.
- **Caret moved by the user** between finish and the query: query once at
  `finish()`; accept slight staleness — it's a transient indicator, not an editing
  anchor.
- **AX hang**: always set a messaging timeout; never block the main thread.
- **Secure input fields**: no caret bounds → fall back or suppress.
- **Multi-monitor + coordinate flip**: the conversion in §"coordinate gotcha".
- **Fast finishes**: minimum visible duration + fade to avoid a flicker.
- **No regressions to the pill**: keep the listening pill behavior untouched.

## Verification

- **Unit tests** (`Tests/`, `RelayTests` target; classes `nonisolated` per the
  MainActor-default rule — see `Tests/TextProcessingTests.swift`):
  - AX-rect → AppKit-rect coordinate conversion with synthetic screen heights and
    multi-display origins (pure function).
  - The fallback-ladder selection logic, given stubbed availability of each rung
    (pure decision function returning which rung + rect).
- **Probe** (optional, very useful): add a `relay-asr-probe` subcommand
  `caret-rect` that prints the current focused element's app, selection range, and
  resolved caret rect (and which rung produced it) — a headless way to survey caret
  support per app. Add any new source path to the probe target in `project.yml`.
- **Interactive (required, TCC-gated)**: with Accessibility granted and the toggle
  on, dictate into TextEdit/Notes (expect a caret-anchored indicator), Safari and an
  Electron app (expect caret or element-frame fallback), and a terminal (expect
  mouse/bottom-center fallback). Confirm: indicator appears during the finalize
  window and disappears on inject; never steals focus or blocks clicks; correct
  placement across two displays; nothing shows when the toggle is off.
- `make build` clean; `make test` green.

## Acceptance criteria

- [ ] Optional, **default-off** setting gates the feature; older `settings.json`
      still decodes.
- [ ] When enabled, a non-activating, click-through indicator appears at the caret
      during the finalize window and dismisses when the final text is injected.
- [ ] Graceful fallback ladder (caret rect → element frame → mouse →
      bottom-center/skip); never hangs on an unresponsive app.
- [ ] Correct screen placement including the AX→AppKit coordinate flip and
      multi-monitor; coordinate + ladder logic unit-tested.
- [ ] No regression to the listening pill or to transcription behavior.
- [ ] Builds and unit tests pass.

## Commit strategy

Land in **distinct, reviewable commits**, each building green (`make build` /
`make test`) before the next:

1. `caretRect()` locator + coordinate-conversion helper + `caret-rect` probe
   subcommand (read-only; no UI).
2. `CaretIndicatorController` + view (non-activating panel), wired but always-off.
3. `AppSettings.showFinalizingIndicator` + `GeneralSection` toggle + Snapshot
   backward-compat.
4. `DictationController` lifecycle hookup (show on `.finishing`, hide on inject),
   gated by the setting; optional diagnostics-strip field.

Use imperative, scoped commit messages.

## Out of scope

- **Live caret tracking during typing** — this is a finish-time indicator only;
  following the caret while streaming is a separate, heavier effort.
- **Input Method Kit** caret access (`attributesForCharacterIndex:lineHeightRectangle:`)
  — only relevant if Relay ever ships an input method; not needed here.
- Showing transcript text / a preview in the indicator — keep it a minimal activity
  affordance.

## Open question for the requester

- **Fallback when the caret is unknown:** show the indicator bottom-center (where
  the pill already lives), or suppress it entirely for that dictation? Plan assumes
  "fall back to bottom-center / let the pill stand in," but suppression is also
  reasonable.
