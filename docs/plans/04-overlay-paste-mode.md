# Plan 4 — "Overlay + paste" insertion mode (settings toggle)

> **For the implementing agent.** Self-contained task brief; you have no memory of
> the conversation that produced it. Read the referenced files before editing. This
> repo is **Relay**, a macOS 26 push-to-talk dictation app (Swift 6, Xcode 26
> MainActor-by-default isolation, XcodeGen from `project.yml`).
>
> **Builds on:** the injection + overlay layers from
> [`01-ax-injection.md`](01-ax-injection.md) (reuse `AXText`, the
> focused-element/selection plumbing, `SyntheticKeys`, `InjectionCoordinator`) and
> the **caret-rect helper** from [`03-caret-overlay.md`](03-caret-overlay.md) §"How
> the OS exposes the caret location" / §1 (reuse `caretRect()` / `CaretLocator`).

## Goal

Add an **optional, settings-toggled second insertion mode**. Today Relay types the
dictation **directly** into the focused field (AX or keystrokes). The new mode —
**"Overlay + paste"** — instead:

1. **Streams the live transcript into Relay's own overlay anchored at the text
   caret**, styling committed text normally and the volatile / low-confidence tail
   differently (dimmer / lighter), so the user gets live feedback **without** ever
   touching the field.
2. **On release, pastes the final text into the field** via the clipboard
   (save → set → ⌘V → restore).

A toggle in Settings chooses **"Type directly" (default, current behavior)** vs
**"Overlay + paste"**. Nothing about transcription changes.

## Why (background)

Direct in-field injection is fragile in **Chromium/Electron** apps (Slack, Claude
desktop, VS Code, Discord, Notion — an increasing share of apps). As documented in
[`01-ax-injection.md`](01-ax-injection.md) and `docs/ax-injection.md`: AX
`selectedText` writes are inert, `setValue` rebuilds the contenteditable DOM and
**collapses the caret to 0**, reads return the placeholder / a frozen length, and
`AXSelectedTextRange` writes are ignored. Synthetic keystrokes work but churn on the
re-writing volatile tail.

Research into how production dictation tools (Wispr Flow, superwhisper, Aqua, Talon,
Espanso) handle this is unanimous: **they paste.** A real ⌘V routes through the
app's native edit pipeline, so the **caret lands after the inserted text for free**,
you get a **single clean undo**, and multiline just works — sidestepping every
Chromium AX problem at once. The only thing paste can't do is **incremental/live**
preview (it's one-shot, and clobbers the clipboard). So we pair it with a **live
caret-anchored overlay** for feedback, and keep the existing direct-typing mode as
the default for users who want in-field live typing.

This is explicitly a **mode**, default off — not a replacement.

## Architecture you're extending

- [`Sources/App/DictationController.swift`](../../Sources/App/DictationController.swift) —
  the conductor. `beginDictation()` wires `streaming.onUpdate` → `injector.render`;
  `finish()` calls `injector.finalize` + saves history. **This is where the mode
  branch goes.**
- [`Sources/Injection/InjectionCoordinator.swift`](../../Sources/Injection/InjectionCoordinator.swift) +
  strategies — the **direct** path (keep, used by "Type directly").
- [`Sources/Injection/SyntheticKeys.swift`](../../Sources/Injection/SyntheticKeys.swift) —
  already posts ⌘-chord `CGEvent`s (used for caret repair). Reuse for ⌘V.
- [`Sources/Shared/Clipboard.swift`](../../Sources/Shared/Clipboard.swift) — today
  copy-only; add save/restore.
- [`Sources/Overlay/OverlayController.swift`](../../Sources/Overlay/OverlayController.swift) +
  `NonActivatingPanel` + `PillView` — the floating pill pattern to copy for the new
  overlay.
- [`Sources/Config/AppSettings.swift`](../../Sources/Config/AppSettings.swift) +
  `Sources/Config/Sections/*` — settings model + UI (see the
  `injectUnconfirmedText` toggle in `GeneralSection` for the exact pattern:
  `@Bindable`, `.onChange { settings.save() }`, optional-decoded `Snapshot` field
  for backward compat).
- `StreamingTranscriber.onUpdate(confirmed, volatile)` — the live hypothesis source.

## Design

### 1. Settings: the mode toggle

- `AppSettings`: add `var insertionMode: InsertionMode` where
  `enum InsertionMode: String, Codable { case typeDirectly, overlayPaste }`,
  **default `.typeDirectly`**. Persist via the `Snapshot` struct with a
  backward-compatible optional field (`var insertionMode: InsertionMode?` → `?? .typeDirectly`),
  exactly like `injectUnconfirmedText` does — so existing settings files don't reset.
- UI: a `Picker` (or labelled `Toggle`) in the **Dictation** section of
  `GeneralSection` (next to "Live unconfirmed text"), with a footer explaining the
  trade-off (overlay+paste = works everywhere incl. Electron, clean caret, but text
  appears on release and uses the clipboard momentarily). Call `settings.save()`
  `.onChange`.

### 2. Caret-anchored transcript overlay

Reuse the `NonActivatingPanel` pattern (borderless, non-activating,
`ignoresMouseEvents = true`, `CGShieldingWindowLevel()`,
`[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`).

- **New `Sources/Overlay/TranscriptOverlayController.swift`** (a sibling controller —
  keep `OverlayController`/pill untouched) owning a panel hosting
  **`TranscriptOverlayView`** (new SwiftUI view).
- **Content / styling:** render `confirmed` text at full opacity and the `volatile`
  tail dimmed (e.g. `.foregroundStyle(.secondary)` or `.opacity(0.5)`, optional
  italics) — the explicit "style partial/low-confidence text differently"
  requirement. A compact glass capsule like the pill; cap width and wrap or
  truncate-from-the-front (show the tail) for long transcripts.
- **Position:** anchor at the caret using the **fallback ladder from Plan 3 §1**:
  `caretRect()` (via `kAXBoundsForRangeParameterizedAttribute`) → focused-element
  frame → mouse → bottom-center. Reuse Plan 3's `CaretLocator` / `AXText.caretRect()`
  if it exists; otherwise implement the minimal helper from Plan 3 §"How the OS
  exposes the caret location" (mind the **AX top-left vs AppKit bottom-left**
  coordinate flip, multi-display). Offset the panel slightly above/below the caret
  so it doesn't occlude. Re-resolve position at session start (and optionally on a
  low-frequency tick); don't thrash AX every render.
- **Updates:** `streaming.onUpdate` pushes `(confirmed, volatile)` to the controller
  (hop to MainActor). The waveform pill may still show (decide: keep the pill for
  waveform/timer AND show the transcript overlay, or suppress the pill in this
  mode — prefer keeping both, the pill is the "recording" affordance).
- **Lifecycle:** shown on session start in overlay-paste mode, updated during
  streaming, hidden after the paste completes (fade like the pill).
- **Threading:** AX caret query on a serial off-main path (reuse the coordinator
  queue or a dedicated one), publish `NSRect?` to the MainActor controller. Off-main
  types `nonisolated` + `@unchecked Sendable`; hop to main for UI (project rule).

### 3. Paste-on-finalize

- **New `Sources/Injection/PasteInjector.swift`** (`nonisolated`, off-main serial
  queue, `@unchecked Sendable` — mirror the other injectors). One entry point,
  e.g. `paste(_ finalText: String)`:
  1. If `IsSecureEventInputEnabled()` → do nothing (or fall back to keystrokes).
  2. **Save** the pasteboard: snapshot `NSPasteboard.general.changeCount` and the
     current items (all types, or at least string + common types — be pragmatic;
     restoring `string` + RTF + fileURLs covers the common cases).
  3. Write `finalText` as the pasteboard string (`clearContents()` + `setString`).
  4. Post **⌘V** via `SyntheticKeys` (add `post(_ kVK_ANSI_V, flags: .maskCommand)`
     or a `paste()` helper). ⌘V inserts at the **user's caret** — which we never
     touched in this mode — so it lands correctly for blank / end / mid-field.
  5. **Restore** the pasteboard once the paste is consumed: poll
     `NSPasteboard.general.changeCount` (it bumps when the app reads the paste) or
     fall back to a delay (~250–400 ms; superwhisper uses ~3 s — measure). Don't
     restore so early the target hasn't pasted yet, nor clobber something the user
     copied meanwhile.
- **Caret:** because nothing was written to the field during streaming (it was all
  in the overlay), the user's real caret is wherever they left it; ⌘V respects it.
  No caret repair needed — this is the whole point.

### 4. Mode routing in `DictationController`

Read `settings.insertionMode` at `beginDictation` (snapshot for the session):

- **`.typeDirectly`** (default): current behavior unchanged — `injector.beginSession`,
  `onUpdate → injector.render`, `finish → injector.finalize`, pill shown.
- **`.overlayPaste`**: do **not** call the injector during streaming. Instead show
  the transcript overlay; `onUpdate → transcriptOverlay.update(confirmed, volatile)`;
  on `finish()` call `pasteInjector.paste(finalText)` and hide the overlay. History
  saving (and Plan 2 stats) stay the same.

Keep the secure-input and focus handling sensible (capture the target at start as
today). `AppModel` constructs the `TranscriptOverlayController` + `PasteInjector`
and wires them like the existing overlay/injector.

### 5. Clipboard save/restore (`Clipboard.swift`)

Add a small value type, e.g. `PasteboardSnapshot`, capturing `changeCount` + the
items, with `Clipboard.save() -> PasteboardSnapshot` and
`Clipboard.restore(_:)`. Keep it nonisolated/Sendable-friendly (it's touched off the
main actor from `PasteInjector`). Be honest that perfectly restoring every exotic
pasteboard type is out of scope — restore string + the common types.

## Files

**New**
- `Sources/Overlay/TranscriptOverlayController.swift` — caret-anchored panel + lifecycle.
- `Sources/Overlay/TranscriptOverlayView.swift` — styled confirmed/volatile transcript.
- `Sources/Overlay/CaretLocator.swift` — only if Plan 3 hasn't landed (else reuse).
- `Sources/Injection/PasteInjector.swift` — clipboard + ⌘V finalize.
- `Sources/Config/InsertionMode.swift` (or inline in `AppSettings`).

**Changed**
- `Sources/Config/AppSettings.swift` — `insertionMode` + persisted `Snapshot` (optional decode).
- `Sources/Config/Sections/GeneralSection.swift` — the mode Picker + footer.
- `Sources/App/DictationController.swift` — mode branch in `beginDictation`/`finish`.
- `Sources/App/AppModel.swift` — construct + wire the new controller/injector.
- `Sources/Shared/Clipboard.swift` — save/restore.
- `Sources/Injection/SyntheticKeys.swift` — add `paste()` (⌘V).

New sources under `Sources/` are globbed by XcodeGen automatically; run `make
generate` (or `make build`). Pure helpers should be reachable by the `RelayTests`
target for unit tests.

## Edge cases & risks

- **Caret rect unavailable** (no AX geometry, terminal, etc.) → fallback ladder;
  transcript overlay still shows (bottom-center). Paste still works (⌘V at caret).
- **Paste blocked** (some password managers, EMM-managed apps, secure input) → ⌘V
  no-ops; detect if feasible (changeCount-based) and optionally fall back to the
  keystroke injector, or surface a hint. At minimum, don't corrupt the clipboard.
- **Clipboard restore timing** — restoring too early loses the paste; too late risks
  clobbering a fresh user copy. Prefer changeCount polling with a max timeout.
- **Held hotkey modifier** — paste runs at `finish()` (after key release), so the
  hold-to-talk modifier is up; still set ⌘V flags explicitly (`SyntheticKeys`
  already does) so nothing inherits.
- **Multi-display / coordinate flip** for the caret rect (Plan 3 §coordinate gotcha).
- **Long transcripts** in the overlay → cap width, wrap or show the tail.
- **Secure input** (password field) → skip paste, skip overlay text, like the
  injector's secure handling.
- **Mode read once per session** — changing the toggle mid-dictation shouldn't
  reconfigure a live session.
- Overlay must be **click-through + non-activating** so it never steals focus or the
  caret.

## Verification

- **Unit** (`RelayTests`, `@testable import Relay`, classes `nonisolated`):
  - Clipboard save/restore round-trip (string + a couple of types).
  - Caret-rect coordinate flip (pure, synthetic screen heights — per Plan 3).
  - Confirmed/volatile split → styled-segment model (pure).
- **Interactive (TCC-gated)**: with Accessibility granted, toggle **Overlay +
  paste**; dictate into a native field, **Slack**, **Claude**, and a terminal:
  - live transcript appears **at the caret** with the volatile tail visibly
    de-emphasized;
  - on release the final text is **pasted at the caret** (cursor ends correctly,
    incl. mid-field), and the **clipboard is restored**;
  - **Type directly** mode (default) is unchanged when the toggle is off.
- `make build` clean; `make test` green.

## Acceptance criteria

- [ ] A settings toggle (default **off** / Type directly) selects between
      "Type directly" and "Overlay + paste".
- [ ] In overlay+paste mode the live transcript streams into a **caret-anchored
      overlay**, with committed vs volatile/low-confidence text **styled
      differently**, and the field is **not** touched until release.
- [ ] On release the final text is **pasted** at the caret (correct cursor
      position across blank/end/mid-field) and the **user's clipboard is restored**.
- [ ] Type-directly mode is byte-for-byte the current behavior.
- [ ] Graceful fallback when the caret rect is unavailable or paste is blocked.
- [ ] Builds + unit tests pass; pure logic is unit-tested.

## Commit strategy

Reviewable slices, each green:
1. Settings: `InsertionMode` + persisted toggle + UI (no behavior change).
2. Caret locator + transcript overlay (display-only; wired to show the live
   transcript in overlay-paste mode, no paste yet — direct injection still runs or
   is suppressed behind the mode flag).
3. Clipboard save/restore + `PasteInjector` (+ `SyntheticKeys.paste`).
4. End-to-end mode routing in `DictationController` + `AppModel` + fallbacks.
5. Styling polish + unit tests.

## Out of scope

- **Deep per-app Chromium integration** (Chrome DevTools Protocol / DOM events) —
  analyzed separately; not this plan.
- Rich-text / formatting in the paste (plain text only for v1).
- Showing the transcript overlay in Type-directly mode.
- Restoring every exotic pasteboard type perfectly.
