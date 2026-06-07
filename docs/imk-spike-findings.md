# IMK spike — findings (does an IMK commit land in Electron?)

> Deliverable for [plan 06](plans/06-imk-spike.md). Pairs with
> [`text-injection-research.md`](text-injection-research.md) §1/§5. The spike code
> lives in `IMSpike/` (target `RelayIMSpike`) and is **disposable** — it is not
> wired into the shipping app.
>
> **Environment:** macOS 26 (Tahoe, build 25F80), Apple Silicon, Swift 6 / Xcode 26,
> ad-hoc signed, unsandboxed. Run 2026-06-05.

## Verdict: **GO** (with a caveat to solve — the activation focus-blink)

An Input Method Kit `insertText:replacementRange:` commit **does land in
Chromium/Electron contenteditable** — empirically confirmed, not just inferred.
The open question the whole IMK direction hinged on (research §5 #1) is
**answered yes**. Live marked-text composition (`setMarkedText:`) also renders, so
a streaming "underline the in-flight tail, finalize behind it, correct in place"
dictation UX is achievable — something the AX/paste path cannot do.

The one real blocker to a *production* feature is **operational, not
architectural**: a programmatic `TISSelectInputSource` does not, by itself, make
the focused app engage the IME; you must force a focus transition (the macism
focus-churn). **Blink resolved (2026-06-06):** the churn *window* can be made
invisible (off-screen, alpha-0), but the IME only engages when our helper does a
real **app activation** (`NSApp.activate`), which briefly flips the **menu bar**
on switch-*in*. A fully-invisible `.nonActivatingPanel` key-focus steal was
tested and does **not** trigger the TSM rebind (no `activateServer:`). The
switch-*back* to a Roman layout needs **no churn at all**. Net residual UX cost:
one brief menu-bar-title flip when dictation starts — not the end of the world,
and it determines polish, not feasibility.

## Per-app result matrix

Marker probe: with `RELAY_IMK_SIMPLE=1`, `insertText("RELAY_IMK_OK ")` on activate.

| App | Bundle id | Commit landed? | Notes |
|---|---|---|---|
| Notes (native AppKit) | `com.apple.Notes` | ✅ yes | clean insert at caret |
| Claude desktop (**Electron/Chromium**) | `com.anthropic.claudefordesktop` | ✅ yes | **the key case** — lands in the message contenteditable |
| System Settings | `com.apple.systempreferences` | ✅ yes | landed in a text field |
| Ghostty (terminal) | `com.mitchellh.ghostty` | ✅ yes | landed at the prompt |
| TextEdit | `com.apple.TextEdit` | _to confirm_ | native control |
| VS Code (Electron) | `com.microsoft.VSCode` | _to confirm_ | |
| Slack (Electron) | `com.tinyspeck.slackmacgap` | _to confirm_ | |
| Discord (Electron) | `com.hnc.Discord` | _to confirm_ | |
| Safari (WebKit) | `com.apple.Safari` | _to confirm_ | |

Confirmed live this run: **Notes, Claude desktop (Electron), System Settings,
Ghostty.** The rest are expected to behave like the confirmed cases (same
NSTextInputClient channel) — fill in as tested.

Raw evidence (`~/relay-imk-spike.log`):

```
activateServer: insertText("RELAY_IMK_OK ") committed to bundle=com.apple.Notes
activateServer: insertText("RELAY_IMK_OK ") committed to bundle=com.anthropic.claudefordesktop
activateServer: insertText("RELAY_IMK_OK ") committed to bundle=com.apple.systempreferences
activateServer: insertText("RELAY_IMK_OK ") committed to bundle=com.mitchellh.ghostty
handle event type=10 chars=d   ← pass-through: our 'd' keystroke flowed to the app
```

## Operational findings

- **Pass-through works** (research §1): `handle(_:client:)` returning `false` lets
  ordinary keystrokes reach the app — our `d` keypresses landed normally while our
  IME was active. So "switch to our IME, still type normally" is viable.
- **No Accessibility / Input Monitoring needed** for the commit itself — text
  arrives via TSM, not a CGEvent tap. (The focus-churn workaround uses only
  `NSApplication.activate` + `NSRunningApplication.activate`, still no AX/IM
  permission. A synthetic-keystroke alternative *would* need Accessibility — TBD.)
- **Consent prompt:** the "…wants to activate the third-party input method" prompt
  appeared **once** on first `TISEnableInputSource`, then did not recur on
  subsequent runs in the same login session. (Research §1 warned it can be
  flaky/recurring; here it was one-and-done after approval.)
- **Switch latency:** `TISSelectInputSource` forward ≈ **180 ms** incl. settle;
  switch-back ≈ **155 ms** (research §5 #5 — previously unquantified; now measured).
- **HUD on programmatic switch (research §5 #4 — was untested): yes, it shows.**
  The near-cursor input-source indicator (icon → "A") appears on the programmatic
  switch. Suppressible via `defaults write … TSMLanguageIndicatorEnabled 0` —
  untested here.
- **The activation model (newly nailed down):** TSM launches the IME process and
  calls `activateServer:` **lazily, only when the focused app's input context
  binds to the IME — i.e. on a real focus transition**, NOT on `TISSelectInputSource`
  alone. A windowless helper that just calls `TISSelectInputSource` updates the
  global current-source + HUD but never engages the IME (the app keeps typing US
  layout). Confirmed: manual menu-switch / click-away-and-back engages it; bare
  programmatic select does not. The fix is the macism focus-churn (below).

## The activation workaround (macism focus-churn)

`Harness.focusChurn` after `TISSelectInputSource` (mode via `RELAY_IMK_CHURN`):

- **`activate`** (default, works): become an `.accessory` `NSApplication`, show an
  **off-screen, alpha-0** window, `NSApp.activate(ignoringOtherApps:true)`, settle
  ~150 ms, then hand focus back to the recorded target via
  `NSRunningApplication.activate()`. That focus transition forces the target's TSM
  input context to rebind to our IME → `activateServer:` fires → commit lands. Runs
  from a separate helper process, no special permission. **Residual:** the app
  activation briefly flips the menu bar (the window itself is invisible).
- **`panel`** (tested, does NOT work): an off-screen alpha-0 `.nonActivatingPanel`
  becomes key (WindowServer key-focus steal, no app activation / menu-bar flip).
  Fully invisible, but on macOS 26 it does **not** trigger the rebind — `activateServer:`
  never fires. Kept only as a documented dead-end.

Research basis: macism (`laishulu/macism`), the LuSrackhall temp-window notes, and
the `NSPanel` nonactivating key-focus-theft writeup (philz.blog). The two known
levers to force the rebind are a key-focus/activation transition or a synthetic
hotkey; there is **no** documented TSM API to rebind a foreign app's input context
without a focus change.

## Registration gotchas discovered the hard way (all now baked into `IMSpike/`)

1. The bundle id **must contain `.inputmethod.`** as an interior label, or the
   login-time scanner won't classify it as an input method and TIS never registers
   it. `com.relay.RelayIMSpike` → silently absent;
   `com.relay.inputmethod.RelayIMSpike` → works.
2. `Info.plist` must use **`tsVisibleInputModeOrderedArrayKey`** (not
   `…OrderArray`) listing the mode id, or TIS surfaces zero modes and drops the
   source.
3. An IMKit method registers **two** TIS entries (a non-selectable container + the
   selectable input *mode*). Select the one with `IsSelectCapable=true`, or
   `TISSelectInputSource` returns `-50`.
4. First registration needs **logout/login** (or at least the mode enabled at
   login) before TIS sees it; mid-session `TISRegisterInputSource` returns 0 but
   won't surface a previously-cached-invalid bundle.
5. `NSLog` from a TSM-launched IME agent does **not** reliably reach the unified
   log; the agent may also have a confined `TMPDIR`. We log to
   `~/relay-imk-spike.log` + a `com.relay.imkspike` os_log subsystem instead.

## How to reproduce

```bash
APP=~/Library/Input\ Methods/RelayIMSpike.app/Contents/MacOS/RelayIMSpike

# build + install (from repo root)
xcodebuild -project Relay.xcodeproj -scheme RelayIMSpike -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
"$APP" harness install "$PWD/build/Build/Products/Debug/RelayIMSpike.app"
"$APP" harness enable            # approve the one-time consent prompt
#  ↳ if `harness list` is empty, log out/in once, then `enable` again

# go/no-go marker probe (single fixed string):
pkill -f "Input Methods/RelayIMSpike"; RELAY_IMK_SIMPLE=1 "$APP" >/dev/null 2>&1 &
# focus a target field, then:
"$APP" harness run               # countdown → switch → focus-churn → commit → switch back
cat ~/relay-imk-spike.log

# streaming-dictation-with-corrections DEMO (default behaviour):
pkill -f "Input Methods/RelayIMSpike"; "$APP" >/dev/null 2>&1 &
# focus a target field, then:
"$APP" harness run               # words stream in underlined + self-correct, then commit
```

`harness` subcommands: `install <app>`, `list`, `list-all` (debug type dump),
`enable`, `disable`, `run [--focus-delay ms] [--settle ms] [--hold ms]`.

## Activation research — can the switch-in flash be eliminated? (2026-06-06)

A dedicated research pass (45 techniques swept across 8 API surfaces, 14 adversarially verified)
answered the blink question definitively.

**Bottom line: NO — a fully-invisible, per-dictation rebind of a *foreign* app's input context is not
achievable on macOS 26.** TSM binds an app's input context to the current IME lazily, on a real
**frontmost-process transition** (`SetFrontProcess`/CPS) — not on `TISSelectInputSource`, not on a
WindowServer key-focus change, not on any TSMDocument property reachable from another process. The
menu bar mirrors the frontmost process, so the transition that rebinds is the same one that flips the
menu bar. They are mechanically inseparable.

**Ranked options (best first):**

| # | Technique | Invisible? | Rebinds foreign app? | Permission | Notes |
|---|---|---|---|---|---|
| 1 | **Persistent always-on IME, gate dictation internally** (Squirrel/Rime model) | ✅ no per-dictation flash | ✅ via the user's own focus changes | none (one-time consent) | IME is the full-time source; Dev-ID/notarized only |
| 2 | **AX text injection** (bypasses IME) — what Apple Dictation actually does | ✅ | n/a (writes text directly) | Accessibility | no marked-text composition UX |
| 3 | **`NSApp.activate` focus-churn** (`.accessory` helper) — the spike baseline = macism | ❌ one menu-bar flip on switch-in | ✅ verified on-device | **none** | switch-back is free |
| 4 | Synthetic "select input source" hotkey via `CGEventPost` | ⚠️ no menu flip but HUD shows | ⚠️ unverified on Tahoe | Accessibility | non-idempotent >2 sources; ISP warns "may cause unexpected behavior on macOS 26" |
| 5 | `.nonActivatingPanel` / CPS key-focus steal | ✅ | ❌ **no** (tested — `activateServer:` never fires) | none | dead end |
| 6 | SLPS `SLPSPostEventRecordTo` (yabai-style) | post-only ✅ | only with `_SLPSSetFrontProcess` (+flash) | none | private SkyLight, fragile — dead end |
| 7 | TSM/Carbon doc APIs (`FixTSMDocument`, `TSMSetDocumentProperty`, `UpdateActiveInputArea`, …) | — | ❌ process-local or 32-bit-only | — | dead end |

**Recommendation:** for a production feature, **option 1 (persistent always-on IME)** is the correct
primary design — the only flash-free path that *keeps* the IMK marked-text composition UX, at the
cost of being the full-time input source. Use the focus-churn (option 3) only for an opt-in
just-in-time switch; keep AX (option 2) as the non-IMK fallback. Apple's built-in Dictation
(`DictationIM.app`, `com.apple.inputmethod.ironwood`) is a hidden palette IME that inserts via the
**Accessibility API** (`AXUIElementSetAttributeValue` + `AXEnhancedUserInterface`) — there is **no**
hidden TSM-rebind primitive and **no** "system dictation insert" API (`SFSpeechRecognizer` recognizes
but does not insert).

**Dead ends (do not re-investigate):** `_stealKeyFocusWithOptions:` panel (tested, fails);
SLPS-post-only; `FixTSMDocument`/`NewTSMDocument` (`#if !__LP64__`, no arm64); `TSMSetDocumentProperty`
override (process-local doc id); `UpdateActiveInputArea`/`SendTextInputEvent` (caller session only);
`TISSetInputMethodKeyboardLayoutOverride` (already-current IME only); `CGSSetSymbolicHotKey` (only
*registers* hotkeys, can't fire them); any cross-process AX focus action.

This conclusion drives the production design in [`docs/plans/08-imk-production.md`](plans/08-imk-production.md)
(persistent-IME primary, focus-churn / AX as fallbacks).

## Cleanup (remove the spike)

```bash
"$APP" harness disable
rm -rf ~/Library/Input\ Methods/RelayIMSpike.app
# then log out/in to fully drop it from the input-source list
```

## Follow-on questions for a production IMK feature

1. **Focus-blink — partially resolved (2026-06-06).** The churn window is now
   invisible (off-screen, alpha-0). A fully-invisible `.nonActivatingPanel`
   key-focus steal was tested and does **not** engage the IME, and no TSM API
   rebinds a foreign app's context without a focus change. So a brief **menu-bar
   flip on switch-in** appears unavoidable with the activation approach; the
   switch-back is free. Remaining options to explore for full polish: a synthetic
   "select next input source" hotkey (needs Accessibility; non-idempotent with >2
   sources), or accepting the one-time flip when dictation starts.
2. **Reads are still unsolved by IMK** (research §1): Chromium's NSTextInputClient
   caches only the current selection / marked text, never the full field. A
   production EDIT feature still needs the AX `AXSelectedTextMarkerRange` path for
   reads/selection (research §2). IMK is an *insert/replace-around-caret* engine,
   not a reader.
3. **Replacement of already-committed text:** `insertText:` with a non-`NSNotFound`
   `replacementRange` needs TSMDocumentAccess, which Chromium only partially
   implements — verify whether document-relative edits land or get dropped. The
   demo sidesteps this by keeping the in-flight tail as *marked* text and only
   correcting within the composition before commit.
4. **Secure input** (password fields) suspends third-party IMEs — expected no-op;
   not yet tested here.
5. **Notarization / a real signed bundle** for distribution (the spike is ad-hoc).
