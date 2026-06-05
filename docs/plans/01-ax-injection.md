# Plan 1 — Accessibility-based text injection (primary), keystrokes as fallback

> **For the implementing agent.** This is a self-contained task brief. You have no
> memory of the conversation that produced it; everything you need is here or in
> the referenced files. Do **not** assume prior context. Read the referenced files
> before editing. This repo is **Relay**, a macOS 26 push-to-talk dictation app
> (Swift 6, Xcode 26 MainActor-by-default isolation, XcodeGen from `project.yml`).

## Goal

Make **Accessibility (AX) direct text manipulation** the *primary* strategy for
inserting/correcting dictated text into the focused field, and keep the existing
**synthetic-keystroke** injector as a *fallback* for apps that don't support AX
text editing. While dictating in AX mode, **read the text preceding the caret**
and use it to improve results (see "Using the prefix" — read the constraints
there). In debug mode, show a small diagnostic panel **above** the dictation pill
reporting: resolved target app, which injection mode is active (AX vs keystroke),
and whether we had to flip "manual accessibility" to get AX to work.

## Why (background)

The current injector ([`Sources/Injection/TextInjector.swift`](../../Sources/Injection/TextInjector.swift))
is *write-only and blind*: it keeps an internal `typed` string, diffs it against
each new hypothesis ([`Sources/Injection/TextDiff.swift`](../../Sources/Injection/TextDiff.swift)),
and emits backspaces + a unicode insert via `CGEvent`. This drifts from reality
whenever the target app mutates text on its own (autocorrect, smart quotes,
auto-capitalization, autocomplete, auto-closing brackets), and it races on fast
event posting. The result is occasional corrupted/weird insertions.

AX manipulation makes the injector **sighted**: read the field's real value and
selection, then replace a known range atomically. Where supported (native Cocoa
text fields, and Electron/Chromium once coaxed), this eliminates backspace-count
drift and lets us read surrounding context. It is not universally supported, so
keystrokes remain the fallback.

## Current architecture you're extending

- [`Sources/App/DictationController.swift`](../../Sources/App/DictationController.swift) —
  the conductor. `beginDictation()` calls `injector.beginSession()`, then on each
  streaming hypothesis builds `target` text, post-processes it, and calls
  `injector.render(_:)`. `finish()` calls `injector.finalize(_:)` and saves to
  history. Holds `onSessionStart`/`onSessionFinish` hooks wired to the overlay.
- [`Sources/Injection/TextInjector.swift`](../../Sources/Injection/TextInjector.swift) —
  `nonisolated final class ... @unchecked Sendable`; all state on a private serial
  `DispatchQueue`. Already: secure-input check (`IsSecureEventInputEnabled()`),
  focus-moved guard (`AXFocus.focusedElement()` + `CFEqual`), grapheme-correct
  backspaces, `event.flags = []` to strip the held hold-to-talk modifier. Contains
  `enum AXFocus` which already reads `kAXFocusedUIElementAttribute` system-wide.
- [`Sources/Overlay/OverlayController.swift`](../../Sources/Overlay/OverlayController.swift) +
  [`Sources/Overlay/PillView.swift`](../../Sources/Overlay/PillView.swift) — the
  floating `NonActivatingPanel` pill (waveform + timer). `OverlayController.show()`
  is called on session start.
- [`Sources/ASR/StreamingTranscriber.swift`](../../Sources/ASR/StreamingTranscriber.swift) —
  LocalAgreement-2 over the batch `AsrManager`; exposes `confirmed`/`volatile`.
- Debug convention already in repo: `RELAY_DEBUG_INJECT=1` env var enables injector
  `NSLog` tracing (see `TextInjector.debugLogging`); `make debug-run` sets it.

## Design

### 1. Introduce an injection-strategy abstraction

Create a protocol so the controller is agnostic to the mechanism, and a
coordinator that picks the strategy per session:

```
protocol TextInjecting: Sendable {
    func beginSession(context: InjectionContext)
    func render(_ target: String)
    func finalize(_ finalText: String)
}
```

- `InjectionContext` (new value type, `Sendable`): the resolved focused element,
  target app identity (bundle id + name + pid), and the captured prefix (see §4).
- Implementations:
  - `AXTextInjector` — new; primary. Replaces a tracked range via AX.
  - `KeystrokeTextInjector` — the existing `TextInjector` logic, renamed/adapted to
    conform. Keep its current behavior intact (it's the fallback).
- `InjectionCoordinator` (new) — owns both, decides per `beginSession` which to use
  based on capability probing (§3), forwards `render`/`finalize` to the chosen one,
  and publishes a `InjectionDebugInfo` snapshot for the overlay (§5).

Keep all of this **`nonisolated` / off the MainActor** and serialized on a single
private `DispatchQueue` exactly like the current injector. **Gotcha (project-wide):**
under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, types/closures default to
MainActor; off-main injector types must be explicitly `nonisolated` and
`@unchecked Sendable` or they trap at runtime. Mirror the existing file's
annotations.

### 2. AX read/write primitives (new file, e.g. `Sources/Injection/AXText.swift`)

Wrap the C AX API in a small `nonisolated enum AXText`. Required calls:

- **Resolve focused element**: reuse/extend `AXFocus.focusedElement()`.
- **App identity**: get the element's pid via `AXUIElementGetPid`, then
  `NSRunningApplication(processIdentifier:)` for bundle id + localized name.
  (Also cross-check `NSWorkspace.shared.frontmostApplication`.)
- **Read value**: `AXUIElementCopyAttributeValue(el, kAXValueAttribute, …)` → String.
- **Read selection/caret**: `kAXSelectedTextRangeAttribute` → `AXValue` of type
  `.cfRange`; extract with `AXValueGetValue(_, .cfRange, &range)`. **AX text ranges
  are UTF-16 / NSString offsets, NOT grapheme clusters** — keep all AX range math in
  UTF-16 and only convert at the boundaries. This differs from `TextDiff`'s
  grapheme counting; do not mix them.
- **Read substring for a range** (for bounded prefix reads):
  `kAXStringForRangeParameterizedAttribute` via
  `AXUIElementCopyParameterizedAttributeValue`.
- **Settability probe**: `AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute, &b)`
  and `kAXValueAttribute`. A field that exposes a value but is not settable → not
  AX-injectable → fall back.
- **Replace a range atomically**: set `kAXSelectedTextRangeAttribute` to the range
  to overwrite (via `AXValueCreate(.cfRange, &range)`), then set
  `kAXSelectedTextAttribute` to the new string. The app performs the replacement.
- **Safety/robustness**: call `AXUIElementSetMessagingTimeout(el, ~0.25s)` so a
  hung/unresponsive target app can't block the injector queue indefinitely.

### 3. Strategy selection + Electron/Chromium "manual accessibility"

On `beginSession`:

1. Resolve the focused element and app identity.
2. If `IsSecureEventInputEnabled()` → inject nothing (existing behavior), mode =
   `.secureBlocked`.
3. Probe AX text capability: element has a settable `kAXValue`/`kAXSelectedText`
   and a readable `kAXSelectedTextRange`. If yes → AX mode.
4. **If the focused element exposes no usable AX text tree AND the app looks like
   Electron/Chromium** (heuristic: bundle id / no AX children / known list), set
   `"AXManualAccessibility"` (and optionally `"AXEnhancedUserInterface"`) to
   `kCFBooleanTrue` on the **application** element
   (`AXUIElementCreateApplication(pid)`), then re-probe once. Record whether this
   flip was necessary (`neededManualAccessibility`) for the debug panel. Note these
   are private/undocumented attribute keys passed as plain strings — they may be
   no-ops on some apps; tolerate failure and fall back.
5. If AX still unusable → keystroke fallback.

Record the decision in `InjectionDebugInfo` (§5) and `NSLog` it under the existing
debug flag.

### 4. Range tracking + rendering in AX mode

- At `beginSession`, capture the caret location `insertionStart` (UTF-16 offset
  into the field value) — this is where dictation begins.
- Maintain `insertedLength` (UTF-16 length of what we've inserted this session).
- On `render(target)`: post-processed `target` is the full desired dictation text.
  Set the selection to `CFRange(location: insertionStart, length: insertedLength)`,
  then set selected text to `target`. Update `insertedLength = target.utf16.count`.
  This replaces the entire previously-inserted region in one atomic op — no diffing,
  no backspaces, autocorrect-safe (the app sees a single edit).
  - Optimization (optional, do only if measured necessary): compute a common UTF-16
    prefix with the prior target and only replace the changed suffix range, to
    reduce churn/caret flicker in large fields.
- On `finalize(finalText)`: same replace with the authoritative text, then clear
  session state.
- **Focus-moved guard**: before each AX write, re-read the focused element; if it
  changed since `beginSession`, do **not** edit the old element. Mirror the
  existing injector's safeguard (commit forward / stop), and surface it in debug.

### 5. Debug overlay (generic, extensible diagnostics strip)

Build this as a **general-purpose diagnostics strip above the pill**, not a
single-purpose injection readout — we will add more signals over time, so design
for append-ability from day one.

- **Model**: a MainActor `@Observable` holder (e.g. `OverlayDiagnostics`) exposing
  an ordered set of labeled fields — simplest is an ordered
  `[(label: String, value: String)]` (or a small struct with a `fields()` accessor)
  built from whatever sources are currently wired. Any subsystem can contribute a
  field without touching the view; adding a future metric = publish one more field.
- **View**: render the fields as compact, monospaced, low-contrast `label:value`
  chips in a small panel just above the pill. The view iterates the fields — it
  does not hard-code injection.
- **Injection contributes (this task)**: `app` (name), `mode`
  (`ax`/`keystroke`/`secure`), `manual-ax` (on/off), `prefix` (char count), and a
  last-op summary (`replaced N` / `focusMoved`). Push these from the off-main
  coordinator by hopping to MainActor
  (`Task { @MainActor in diagnostics.set(...) }`), per the project's off-main→main
  isolation rules.
- **Existing signals worth surfacing now** (all already observable — wire whatever
  is cheap, leave the rest as trivial follow-ups): active mic device name + level
  (`MicrophoneCapture.activeDevice?.name`, `.level`), dictation `phase`
  (`DictationController.Phase`), elapsed time, model status (`ASREngine.status`),
  and streaming buffer-seconds / current re-inference interval if you expose them
  from `StreamingTranscriber`. Start with `app/mode/manual-ax/prefix` + mic name.
- **Placement**: either expand the overlay panel and stack the strip above
  `PillView` inside the hosting view, or a second tiny `NonActivatingPanel` anchored
  above the pill. Prefer whichever leaves the pill layout untouched.
- **Gating**: show only under the debug flag. Reuse `RELAY_DEBUG_INJECT=1`, or
  introduce a broader `RELAY_DEBUG=1` that also implies the injector tracing — if
  you add a new flag, update the `Makefile` `debug-run` target and the README.
  Default builds show nothing extra.

### 6. Unifying dictated text with the already-written prefix  ⚠️ READ FIRST

**Can the model use text context at all? No — not through FluidAudio, and not
worth forcing.** Parakeet TDT is a Token-and-Duration Transducer; its prediction
network is autoregressive over previously *emitted* tokens (a small internal LM),
so in theory a decoder could be primed with the prefix tokens, or switched into
ITN/punctuation mode by seeding a control token (`<|itn|>` / `<|pnc|>`). Both are
closed to us:

- FluidAudio exposes only `TdtDecoderState.make(decoderLayers:)` (a fresh, zeroed
  prediction-net state) and `transcribe(audio, decoderState:&, language:)`. There
  is **no API to seed initial tokens or warm the state from text**. Prefix priming
  would require forking FluidAudio / reimplementing the TDT decode loop, and
  transducer prediction nets are deliberately tiny/weak LMs, so the payoff is
  marginal and can *introduce* errors. **Verdict: don't.**
- The `<|itn|>` / `<|pnc|>` tokens exist in the tokenizer vocabulary but the decode
  loop never emits/consumes them; enabling them would need both this CoreML export
  to support prompt-conditioned output (unverified) and a way to seed the initial
  token (not exposed). **Verdict: out of scope.** *Optional bounded spike only if
  curious:* inspect `AsrManager.config`/`ASRConstants` for decoding options and
  whether the tokenizer round-trips those specials — but assume "no" and don't
  block on it. See [`docs/INTEGRATION-NOTES.md`](../INTEGRATION-NOTES.md).

**So: treat the model as audio → plain text. Unifying with the prefix is a
text-layer problem**, solved at injection/post-processing time.

**Capture the prefix once.** At `beginSession`, read the bounded text immediately
before the caret (≤ ~256 UTF-16 units via the parameterized substring attribute)
and freeze it as immutable session context. Do **not** re-read it mid-session — our
own insertions follow the caret, so a re-read would read our own output back.
(Optionally also capture the single char *after* the caret for trailing-space
decisions.) Treat the prefix as sensitive: never log its contents, only its length.

**Pipeline ordering.** Apply unification as the **last** step, after existing
post-processing, on the post-processed dictation + the frozen prefix:

  ASR text → ITN (if on) + user replacements (`TranscriptPostProcessor`)
           → unify-with-prefix (spacing → dedup → capitalization)
           → inject

Run it on **every** render (not just final) so the seam stays stable as the
volatile tail rewrites. Make the unifier a pure function that returns the dictation
**unchanged when `prefix == nil`** — in keystroke-fallback mode we usually have no
prefix and insert verbatim (current behavior).

**Unification rules — deterministic baseline (Tier 1 — the DECIDED v1 scope):**

1. **Spacing.** If the prefix is non-empty, doesn't end in whitespace, and the
   dictation's first char isn't whitespace or attaching punctuation (`,.!?;:)`),
   insert one space at the seam. Collapse accidental doubles. Peek at the post-caret
   char to avoid creating `"word  "` before existing whitespace.
2. **Dedup / overlap.** Longest *token-level* overlap between the prefix tail (last
   ~6 words) and the dictation head, case-insensitive, with a minimum overlap
   (≥2 tokens, or ≥1 long token) to avoid false positives on common words; drop the
   overlapping head from the dictation.
3. **Capitalization.** Capitalize the dictation's first letter if the prefix is
   empty or ends a sentence (terminator + optional closing quote/bracket/space).
   Mid-sentence: leave the model's casing alone (don't force-lowercase — proper
   nouns).

All three are pure string functions → unit-test as `(prefix, dictation) → expected`.

**⚠️ Verify raw model output format first.** Whether rule 3 fires depends on what
Parakeet v3 emits — does it already capitalize/punctuate, or output
lowercase/no-punctuation? Characterize it with
`relay-asr-probe transcribe <sample.wav>` and read the raw text **before** tuning
the casing/punctuation rules. If the model already punctuates, rule 3 mostly defers
to it; if not, we own it.

**Higher tiers — explicitly OUT of scope for v1 (do NOT build):**
- **Tier 2 — NaturalLanguage (`NLTagger`)**: real sentence-boundary detection for
  the casing decision instead of char heuristics. On-device, modest gain.
- **Tier 3 — LLM rewrite**: feed `(prefix, dictation)` to a small model
  ("continue this naturally"). The ceiling (casing, punctuation, style-match,
  grammatical merge) at the cost of latency / privacy if cloud.

These are recorded only as future directions; structure the unifier so a smarter
strategy could slot in later, but ship Tier 1.

## Files

**New**
- `Sources/Injection/AXText.swift` — AX read/write primitives + app identity.
- `Sources/Injection/AXTextInjector.swift` — AX strategy.
- `Sources/Injection/InjectionCoordinator.swift` — strategy selection + debug info.
- `Sources/Injection/InjectionContext.swift` (+ `InjectionDebugInfo`, `InjectionMode`).
- Overlay debug view (new file or additions to `PillView.swift` / `OverlayController.swift`).

**Changed**
- `Sources/Injection/TextInjector.swift` — adapt to `TextInjecting` (rename to
  `KeystrokeTextInjector` or keep name + conform). Preserve all current behavior.
- `Sources/App/DictationController.swift` — depend on `TextInjecting`/coordinator;
  pass `InjectionContext`; thread prefix into post-processing.
- `Sources/App/AppModel.swift` — construct the coordinator; wire debug info to the
  overlay.
- `Sources/Overlay/*` — debug panel.
- `Makefile` / `README.md` — only if you add a new debug flag.

**Project files**: new sources under `Sources/` are picked up by XcodeGen
automatically (the `Relay` target globs `Sources` minus `Probe/**`). If you add AX
helpers that the `relay-asr-probe` target should also use, add those paths
explicitly under the `relay-asr-probe` target in `project.yml`. After any structural
change run `make generate` (or just `make build`, which generates first).

## Edge cases & risks

- **UTF-16 vs grapheme**: AX ranges are UTF-16; `TextDiff` is grapheme-based. Keep
  them separate. Emoji/CJK/combining marks will break if you mix units.
- **Read-only / value-but-not-settable** fields → fall back, don't error.
- **Mid-session focus change** → stop editing the old element (existing guard).
- **AX hangs**: always set a messaging timeout; never call AX on the main thread
  in a way that can block UI.
- **Electron flip may be a no-op** on some apps or require the app to be frontmost;
  tolerate and fall back.
- **Caret moved by the user mid-dictation** in AX mode: range tracking assumes the
  inserted region is contiguous from `insertionStart`. If `kAXSelectedTextRange`
  no longer matches expectations, fall back to append-forward or keystrokes for the
  rest of the session rather than corrupting text.
- **Secure input** mid-session (user focuses a password field): re-check and stop.
- **Threading/Sendability**: respect the MainActor-default isolation gotcha; keep
  off-main types `nonisolated` + `@unchecked Sendable`, hop to MainActor only to
  touch UI/overlay.

## Verification

- **Unit tests** (`Tests/`, `RelayTests` target, `@testable import Relay`; classes
  must be `nonisolated` per the MainActor-default rule — see existing
  `Tests/TextProcessingTests.swift`):
  - Range/replacement math in UTF-16 (prefix-common, suffix-replace) — pure logic,
    no live AX.
  - Prefix spacing/capitalization/dedup decisions — pure functions over sample
    (prefix, dictation) pairs.
- **Probe** (optional, very useful): add a `relay-asr-probe` subcommand
  `ax-dump` that prints the current system-focused element's app, value length,
  selection range, and settability — a headless way to inspect AX support per app.
  Add the new AX source path(s) to the `relay-asr-probe` target in `project.yml`.
- **Interactive (required, TCC-gated — cannot be done headlessly)**: with
  Microphone + Accessibility granted, dictate into: a native Cocoa field (TextEdit/
  Notes), Safari, an Electron app (VS Code/Slack), and a terminal. Confirm AX mode
  is chosen where expected (debug panel), keystroke fallback elsewhere, no
  corruption, correct spacing/capitalization from the prefix, and the manual-AX
  flip indicator shows for Electron. Confirm the debug panel renders above the pill
  and only under the debug flag.
- `make build` clean; `make test` green.

## Acceptance criteria

- [ ] AX is the primary path; keystrokes are a working fallback selected
      automatically when AX text editing is unavailable.
- [ ] Per-session strategy decision considers secure input, AX settability, and an
      Electron manual-accessibility flip (recorded when used).
- [ ] In AX mode, the bounded caret-prefix is read and used for spacing/
      capitalization/dedup of the dictated text; prefix contents are never logged.
- [ ] A debug-only, **extensible** diagnostics strip above the pill shows at least
      app, mode, manual-AX flag, and prefix length, and is designed so more signals
      can be appended later without changing the view; hidden in normal builds.
- [ ] No regressions to the existing keystroke behavior (secure-input skip,
      focus-moved guard, modifier-stripping, grapheme backspaces).
- [ ] Builds and unit tests pass; new logic is unit-tested where it's pure.

## Commit strategy

Land this in **distinct, reviewable commits** rather than one big change. Each
slice should build green (`make build` / `make test`) before the next. Suggested
slices:

1. Strategy abstraction: `TextInjecting` protocol + adapt the existing keystroke
   injector to conform (no behavior change).
2. AX primitives (`AXText.swift`) + an `ax-dump` probe subcommand (read-only — no
   injection yet).
3. `AXTextInjector` + `InjectionCoordinator`: capability probing, Electron
   manual-accessibility flip, keystroke fallback.
4. Generic overlay diagnostics strip + wiring (gated on the debug flag).
5. Prefix capture + unification pipeline + its unit tests.

Use imperative, scoped commit messages.

## Out of scope

- InputMethodKit / marked-text ("being-corrected" underline inside the field) — a
  much larger, separate effort (requires shipping an input-method bundle). Not this
  task.
- Any LLM/network post-processing.
