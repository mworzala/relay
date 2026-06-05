# Text injection (Accessibility-primary, keystrokes fallback)

How Relay gets dictated text into whatever field has keyboard focus. AX
(Accessibility direct manipulation) is the primary path; synthetic CGEvent
keystrokes are the fallback. A coordinator picks per session and can hand off
mid-session.

## Components (`Sources/Injection/`)

- **`InjectionContext.swift`** — `TextInjecting` protocol + the Sendable value
  types: `InjectionContext` (resolved element, app identity, frozen caret prefix,
  reporter/fallback closures), `InjectionMode` (`ax`/`keystroke`/`secure`),
  `InjectionDebugInfo` (overlay snapshot).
- **`InjectionCoordinator.swift`** — per-session strategy selection, the
  Electron/Chromium manual-accessibility flip, bounded caret-prefix capture
  (≤256 UTF-16, contents never logged), debug publishing, and the AX→keystroke
  re-route.
- **`AXTextInjector.swift`** — the AX strategy: tracks the inserted region, writes
  via `selectedText` (native) or `value` (Chromium), verifies the first write,
  and always parks the caret at the end.
- **`KeystrokeTextInjector.swift`** — the CGEvent fallback (modifier-stripping,
  focus-moved guard, grapheme backspaces). Unchanged behavior from before AX.
- **`AXText.swift`** — thin wrappers over the AX C API. **All offsets are UTF-16
  (NSString) units**, never grapheme clusters. Includes `AXEdit` (pure UTF-16
  prefix/suffix diff with surrogate-pair-safe boundaries) and `splicedValue`
  (pure value-mode splice). Both unit-tested.
- **`PrefixUnifier.swift`** — Tier-1 deterministic unification of the dictation
  with the existing caret prefix: dedup an overlapping head, capitalize after a
  sentence terminator / at field start (never lowercases), insert a seam space.
  Pure functions, unit-tested.

## Per-session strategy selection

1. **Secure input** (`IsSecureEventInputEnabled`) → inject nothing.
2. Resolve the **system-wide** focused element; probe `supportsTextEditing`
   (readable `kAXSelectedTextRange` + settable `kAXSelectedText` **or** `kAXValue`).
3. If not usable (incl. a `nil` focused element), **flip manual accessibility** on
   the *frontmost app's pid* and re-resolve via the **application** element. Done
   for any app — the keys are a harmless no-op on non-Chromium ones — over a short
   bounded retry window (Chromium builds its tree asynchronously).
4. Usable text element → **AX**; otherwise **keystroke**.
5. In AX, the **first write is verified** (did the field content change?). If the
   `selectedText` write was inert, the `value` write is tried; if that's also
   inert, the session **falls back to keystrokes** (caret restored to the
   insertion point, captured prefix preserved so spacing/caps still apply).

## Electron / Chromium notes (hard-won — read before changing this)

Chromium/Electron AX is the reason most of the complexity exists.

- **System-wide focus is `nil`.** Chromium exposes its focused web text control on
  the **application** element (`AXUIElementCreateApplication(pid)` →
  `kAXFocusedUIElement`), and **only after** `AXManualAccessibility` /
  `AXEnhancedUserInterface` are set on the app element. The system-wide
  `kAXFocusedUIElement` query stays nil for web content.
- **"Settable but inert."** A Chromium field can report `settable[selText=true
  value=true]` yet silently ignore writes. **`kAXNumberOfCharacters` is frozen**
  (we saw a constant `1`), so any length-based logic is wrong — **verify writes by
  comparing the field's value (content) before/after, never by length.**
- **`selectedText` writes are often inert; `value` (whole-`kAXValue`) writes may
  work.** So the injector tries `selectedText` first, then `value`.
- **`setValue` resets the caret to 0** on some Chromium fields even when the write
  is inert — restore the caret before any keystroke fallback or it prepends.
- **Per-app, it varies.** In testing: Slack's value-write was honored (real AX);
  Claude's was inert (clean keystroke fallback). Both end up inserting correctly.
- Reaching the Chromium control requires Accessibility permission AND the flip;
  the manual-AX keys persist for the app's process lifetime, so the *first*
  session after launch may miss the async tree build and fall back, while later
  sessions in the same app succeed.

## Responsiveness / streaming

- **Mic warms on key-down.** Capture + a streaming pre-roll start in `handlePress`
  (not after the arm delay), so the ~0.3–0.5s hardware startup overlaps the arm
  window and the opening words aren't clipped (`StreamingTranscriber.prepare()`).
- **Snappier cadence.** `minSamples` 0.3s, `baseIntervalMs` 140ms — earlier first
  word and faster LocalAgreement commits.
- **"Live unconfirmed text"** (General → Dictation, default **on**): inject
  confirmed + the volatile tail — responsive, but the tail may rewrite/backspace
  as it settles. **Off** injects only the committed (monotonic) prefix — smooth,
  append-only, never backspaces; the tail lands from the authoritative final pass
  on release. Worth turning off for keystroke/Electron apps, where each correction
  costs visible backspaces.

## Debug / diagnostics

- `RELAY_DEBUG=1` (or `make debug-run`): shows the **diagnostics strip** above the
  pill (app, mode, manual-ax, prefix length, last op, mic) **and** injector
  tracing. `RELAY_DEBUG_INJECT=1` is tracing only. The coordinator logs a
  per-session `probe` / `re-probe` line (`settable[selText=… value=…]`) to diagnose
  per-app AX support — field contents are never logged, only lengths.
- `relay-asr-probe ax-dump` prints the focused element's AX text support headlessly.

## Tests

`Tests/` (RelayTests, `@testable import Relay`, `make test`): `AXEdit` UTF-16 range
math incl. surrogate pairs, `splicedValue`, `PrefixUnifier` rules, `TextDiff`.
Live AX behavior is TCC-gated and verified interactively.

## Known limitations / possible future work

- Electron AX is per-app and depends on Chromium honoring `value` writes; inert
  apps cleanly fall back to keystrokes.
- In keystroke mode, the unstable volatile tail causes backspace churn on long
  dictations — "Live unconfirmed text" off avoids it; a future option could keep
  volatile injection only in AX mode (cheap there) and stay confirmed-only on
  keystroke.
- Not attempted: walking the Chromium AX subtree to find the focused field when
  the app element reports none; eagerly flipping manual-AX when an app activates
  (so the first session isn't a fallback); InputMethodKit marked text
  (out of scope — needs a shipped input-method bundle).
