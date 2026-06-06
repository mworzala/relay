# Plan 8 — Production IMK dictation input method (the Chromium/Electron insertion path)

> **For the implementing agent.** Self-contained brief; you have **no memory** of the spike that
> produced it and **this branch (`main`) does not contain the spike code**. Relay is a macOS 26
> push-to-talk dictation app (Swift 6, Xcode 26 MainActor-by-default isolation, XcodeGen from
> `project.yml`, ad-hoc signed / unsandboxed). Everything you need to avoid repeating the spike's
> mistakes is in this doc — read **§3 (hard-won setup gotchas)** before writing any code.
>
> **Provenance.** A throwaway spike (plan 06, run on a separate branch) empirically proved that an
> IMK `insertText:replacementRange:` commit **lands in Electron/Chromium (Claude desktop) and native
> apps**, that live `setMarkedText:` composition renders (so streaming dictation with in-place
> corrections works), that pass-through typing works, and that **no Accessibility permission** is
> needed for the commit. This plan productionizes that result. The spike's per-app matrix, measured
> latencies, and the full gotcha list are summarized below so this plan stands alone.

## Goal

Add IMK as an **optional, config-gated, app-managed** text-insertion path — the premium route for
Chromium/Electron apps (Slack, VS Code, Discord, Claude desktop, Notion) where Relay's AX/paste path
is unreliable. Specifically:

- A **Settings toggle**: "Insert via input method (better Electron/Chromium support)" — **off by
  default**, experimental.
- A **mode picker** (enabled only when the toggle is on) letting the user choose how the IME engages:
  - **Always on** (recommended, **no flash**) — Relay's IME becomes the active input source while the
    feature is enabled and passes through all normal typing; dictation is gated internally. No
    per-dictation switch, no menu-bar flicker. Tradeoff: Relay is the full-time input source (the
    input menu shows "Relay").
  - **Just-in-time** — Relay's IME is selected only for the duration of each dictation, then the
    previous source is restored. Relay is *not* your full-time input source, but each dictation
    **start** shows a brief menu-bar flip (the switch-back is free). This flip is **unavoidable** —
    see §2.
- When the user enables it and the keyboard isn't installed yet, show a **"Set up…" button** that
  installs + registers + enables the bundled IME (with the consent prompt and any logout guidance).
- **Relay manages the IMK server process itself** — launches it, keeps it alive while engaged,
  terminates it when the feature is disabled. Nothing is installed until the user explicitly requests
  it.
- During dictation: stream ASR text in (interim as marked/underlined text, finalized phrases
  committed). The two modes differ only in *when* the IME is the active source (always vs per-dictation).
- If the IME is not installed/enabled, **transparently fall back** to the existing AX/paste path.

## Why

IMK is the only insertion path that goes through the native `NSTextInputClient`/TSM channel Chromium
implements for IME input (`insertText:` → Chromium `ImeCommitText()` → Blink editor). The spike
confirmed the commit lands in Electron where AX writes are inert, with a correct caret and no
Accessibility permission. It is also the only path that can show a **live composition preview**
(underlined interim text that self-corrects before commit) — something paste/AX cannot do.

## Non-goals / scope limits (do not scope-creep)

- **Reads are NOT solved by IMK.** Chromium's `NSTextInputClient` caches only the current selection
  and marked text — never the full field. A production EDIT/voice-command feature still needs the AX
  `AXSelectedTextMarkerRange` path (plan 05). IMK here is an **insert / replace-around-caret** engine.
- **Replacement of already-committed text** via a non-`NSNotFound` `replacementRange` needs
  TSMDocumentAccess, which Chromium only partially implements — do NOT rely on it. Keep the in-flight
  tail as *marked* text and only correct within the composition before committing.
- **Secure input** (password fields) suspends third-party IMEs — expected no-op; fall back.
- **Mac App Store build** can't ship this (sandbox forbids it) — same as the rest of Relay.

---

## 1. Architecture

Three pieces:

### 1a. The IME helper bundle — `RelayInputMethod.app` (new, separate target)

A minimal IMK input method, **embedded inside Relay.app** and copied to `~/Library/Input Methods/`
on setup. It is a background agent (`LSUIElement`) whose only job during dictation is to apply
text-insertion events it receives from the main app to the currently-focused client.

- **`IMKServer`** created at launch on the connection named **exactly**
  `$(PRODUCT_BUNDLE_IDENTIFIER)_Connection`.
- **`IMKInputController`** subclass (`@objc(...)`-named, `nonisolated` — see §3) that:
  - on `activateServer:` records the current `IMKTextInput` client and notifies the main app it is
    engaged;
  - applies `setMarkedText:` / `insertText:` requests arriving over IPC (§1c) to that client;
  - returns **`false`** from `handle(_:client:)` so normal typing passes through;
  - on `deactivateServer:` clears the client and notifies the main app.
- It carries **no ASR, no audio, no UI**. All dictation logic stays in the main app; the helper is a
  thin insertion proxy. (It must be a separate bundle because macOS requires an input method to be
  its own bundle in `~/Library/Input Methods/`.)

### 1b. The main app — install/lifecycle/orchestration

- **`IMKInstaller`** — copies the embedded `RelayInputMethod.app` to `~/Library/Input Methods/`,
  `TISRegisterInputSource`, `TISEnableInputSource` (triggers the one-time consent prompt), verifies
  it appears in the source list, and detects the "needs logout/login" case (§3.4). Also `uninstall`.
- **`IMKProcessManager`** — **Relay owns the helper process lifecycle.** Launch the installed helper
  (`NSWorkspace.openApplication` on the installed `.app`, or `Process`) when dictation-via-IME is
  active; keep a handle; terminate it when the feature is disabled or the app quits. Do NOT rely
  solely on TSM to spawn it. (TSM *will* also spawn it on selection; design the helper so a
  Relay-launched instance and a TSM-launched instance don't fight — single IMKServer connection name,
  and make IPC idempotent. Simplest: let Relay launch it and have the helper be a singleton via a
  guard on the Mach service name.)
- **`IMKSwitcher`** — `TISSelectInputSource(ours)` + the focus-churn to engage it (§2), records the
  previous source, and restores it on dictation end (the restore needs **no** churn — see §2).

### 1c. IPC between main app and helper

The helper holds the active `IMKTextInput` client; the main app produces the text. Wire them with a
**named Mach service** the helper vends and Relay connects to (both are unsandboxed, so a global Mach
name works; `NSXPCConnection` with a named `NSXPCListener`/Mach service, or `CFMessagePort`).

- Helper → app: `engaged(clientBundleID)`, `disengaged`.
- App → helper: `setMarked(String)`, `commit(String)`, `clear`. (Mirror the spike demo: stream
  interim hypotheses as marked text, commit finalized phrases.)
- Keep the protocol tiny and idempotent; tolerate the helper restarting.

### 1d. Orchestration

**Primary — persistent IME (§2b), no per-dictation switch:**
1. **On enable** (once): `IMKSwitcher` selects Relay's IME as the current source and leaves it. The
   helper binds to whatever field the user focuses, via the user's *own* focus changes — no churn.
2. **PTT down**: main app signals the helper "dictation on" over IPC; helper begins accepting
   `setMarked`/`commit`. (No input-source switch, no flash.)
3. **ASR streams**: `setMarked(interim)` as hypotheses arrive, `commit(finalized)` as phrases
   stabilize → helper applies them to the already-bound client (correct caret, Blink commit).
4. **PTT up**: final `commit`; helper returns to pure passthrough.
5. **On disable**: `IMKSwitcher` restores the user's previous Roman source (free, no churn).

**Alternative — just-in-time switch (opt-in, has the menu-bar flash):** at PTT-down record the
current source, `TISSelectInputSource(ours)` + focus-churn (§2) to engage, stream, then restore at
PTT-up. Latency budget (measured in the spike): switch-in ≈ **180 ms**, switch-back ≈ **155 ms**.

**Always:** on failure / secure-input / no bound client, fall back to the existing AX/paste path.

---

## 2. Activation — the one genuinely tricky part (READ THIS)

`TISSelectInputSource()` only updates the **global** current-source record (the menu-bar HUD changes,
`TISCopyCurrentKeyboardInputSource` agrees). It does **NOT** make the focused foreign app's TSM input
context re-bind to the new IME — that happens only on a **real focus transition**. A windowless
helper that just calls `TISSelectInputSource` will see the HUD change but the IME **never engages**
(`activateServer:`/`handleEvent:` never fire; keystrokes stay on the old layout). This cost the spike
many cycles — do not rediscover it.

**Working mechanism (the "macism focus-churn"):** after `TISSelectInputSource(ours)`, momentarily
make a tiny helper `.accessory` `NSApplication` active via `NSApp.activate(ignoringOtherApps:true)`
with an **off-screen, alpha-0** window, settle ~150 ms, then hand focus back to the recorded target
app (`NSRunningApplication.activate()`). That focus transition forces the rebind → `activateServer:`
fires. Runs from a helper process; **no Accessibility permission**.

**Known-invisible-but-DOESN'T-WORK (do not retry):** an off-screen alpha-0 `.nonActivatingPanel`
becoming key (a WindowServer key-focus steal) is fully invisible but **does not trigger the TSM
rebind** — tested on macOS 26, `activateServer:` never fired.

**The residual UX cost:** the churn *window* is invisible, but the app activation briefly **flips the
menu bar** on switch-*in*. The switch-*back* to the user's Roman layout needs **no churn at all**, so
it's free. Net: one brief menu-bar flicker when dictation starts.

> **✅ Blink-mitigation research — RESOLVED (a fully-invisible per-dictation switch is impossible).**
> A dedicated research pass (45 techniques across CPS/SkyLight key-focus APIs, TSM/Carbon
> cross-process nudges, the built-in-Dictation mechanism, AX-focus rebind, no-menu-bar activation
> variants, synthetic hotkeys, and the always-on IME; 14 adversarially verified) concluded:
>
> **TSM binds an app's input context to the current IME lazily, on a real *frontmost-process*
> transition (`SetFrontProcess`/CPS) — NOT on `TISSelectInputSource`, NOT on a WindowServer key-focus
> change, NOT on any TSMDocument property reachable from another process. The menu bar mirrors the
> frontmost process, so the transition that performs the rebind is the same one that flips the menu
> bar — they are mechanically inseparable.** Therefore, for the **switch-on-dictation** model, the
> menu-bar flip on switch-in is **unavoidable**. (All the clever escapes are verified dead ends — see
> §2a. The only escapes from the flash are to *not switch* (§2b, recommended) or to *not use IMK*
> (the existing AX path).)

### 2a. Verified dead ends (do NOT re-investigate)

- **`.nonActivatingPanel` / CPS key-focus steal** (`_stealKeyFocusWithOptions:`) — invisible but
  `activateServer:` never fires; TSM follows the frontmost *process*, not the WindowServer key-focus
  stack. (Tested on-device in the spike — failed.)
- **SLPS `SLPSPostEventRecordTo`-only flip** (yabai-style) — invisible XOR effective; yabai always
  pairs it with `_SLPSSetFrontProcessWithOptions`, which flips the menu bar anyway. Private SkyLight,
  version-fragile.
- **TSM/Carbon doc APIs** (`FixTSMDocument`/`ActivateTSMDocument`/`NewTSMDocument` — `#if !__LP64__`,
  don't compile on arm64; `TSMSetDocumentProperty` with an input-source override —
  `TSMDocumentID` is process-local, no foreign-app handle; `UpdateActiveInputArea`/`SendTextInputEvent`
  — caller's own session only; `TISSetInputMethodKeyboardLayoutOverride` — only sets the ASCII layout
  of an already-current IME).
- **`CGSSetSymbolicHotKey`** — only *registers* hotkeys; there is no call to *fire* one.
- **Any AX action at the target** (set `kAXFocusedUIElement`, blur+refocus, AXRaise, post a
  notification) — weaker than the already-failed panel; an AX focus write in Chromium doesn't move the
  AppKit firstResponder, and you can't post AX notifications cross-process.
- **A "system dictation insert" API** — does not exist. `SFSpeechRecognizer`/AssistantServices
  recognize speech but do not insert text. Apple's built-in Dictation (`DictationIM.app`,
  `com.apple.inputmethod.ironwood`) is a *hidden palette IME* that inserts via the **Accessibility
  API** (`AXUIElementSetAttributeValue` + `AXEnhancedUserInterface`), not a hidden TSM rebind.

### 2b. RECOMMENDED PRIMARY ARCHITECTURE — persistent always-on IME, gate dictation internally

Because the per-dictation switch flash is unavoidable, the research's top recommendation (and the
model every real macOS IME — Squirrel/Rime/azooKey — uses) is to **not switch per dictation at all**:

- When the feature is enabled, select Relay's IME as the current source **once** and leave it active
  full-time (the rebind then rides the **user's own ordinary focus changes** — no churn, **no flash,
  no Accessibility**).
- The controller returns `false` from `handle(_:client:)` for **all** ordinary keystrokes
  (passthrough — verified in the spike), so typing is unaffected.
- The existing global push-to-talk hotkey toggles "dictation mode" inside the controller; only then
  does Relay drive `setMarkedText:`/`insertText:` on the **already-bound** client.

**Tradeoffs (real, accept them consciously):** the menu shows "Relay" as the current input source
full-time while enabled (the near-cursor HUD is suppressible via
`defaults write -g TSMLanguageIndicatorEnabled 0`; the menu-bar title is not); **passthrough must be
flawless** (bundle-id-gate behavior Squirrel-style); secure/password fields revert to Roman and
bypass the IME (harmless); install is `~/Library/Input Methods/` so **Developer-ID/notarized only,
never Mac App Store**.

**Decision for implementation:** ship **both engagement modes as a user-selectable config option**
(see Goal + §5) — they share all the install/IPC/insertion machinery and differ only in *when* the
IME is the active source:

- **Always on (2b)** — default/recommended; flash-free; Relay is the full-time source. Engage once on
  enable; no churn.
- **Just-in-time (§2 focus-churn, `activate` mode)** — Relay isn't the full-time source, at the cost
  of one menu-bar flip per dictation start.

Implement the engage/disengage step behind **one swappable strategy** (`IMKEngagement` with
`alwaysOn` / `justInTime` conformers) so the mode is a runtime switch, not two code paths. Keep the
existing **AX/paste path** as the non-IMK fallback when the IME isn't installed/enabled or in secure
fields.

> Full research report (ranked options, exact call sequences, sources) is reproduced in the spike's
> `docs/imk-spike-findings.md` on the spike branch; the load-bearing conclusions are inlined above so
> this plan stands alone on `main`.

---

## 3. Hard-won setup gotchas (every one cost the spike real time — bake them in)

1. **Bundle id MUST contain `.inputmethod.` as an interior label.** The login-time scanner of
   `~/Library/Input Methods/` only classifies a bundle as an input method if its identifier has
   `.inputmethod.` in the middle (e.g. `com.relay.inputmethod.RelayInputMethod`). Without it, TIS
   **silently never registers it** — it won't appear anywhere, no error. Confirmed against every
   Apple + third-party IME (Squirrel `im.rime.inputmethod.Squirrel`, azooKey
   `dev.ensan.inputmethod.azooKeyMac`).

2. **`Info.plist` keys (model on Apple's AinuIM):**
   - `LSUIElement = true` (background agent, no Dock icon).
   - `InputMethodConnectionName = $(PRODUCT_BUNDLE_IDENTIFIER)_Connection` (read it back at runtime
     to create the `IMKServer`).
   - `InputMethodServerControllerClass` = the controller class name. Because the class is
     `@objc(RelayInputMethodController)`, the **bare** name works; if you DON'T use an explicit
     `@objc(...)` name, you must use the module-qualified `$(PRODUCT_MODULE_NAME).Class`.
   - `ComponentInputModeDict` → `tsInputModeListKey` → one mode dict whose key == its
     `TISInputSourceID`, with `tsInputModeIsVisibleKey = true`, `tsInputModeScriptKey =
     smUnicodeScript`, `TISIntendedLanguage = en`.
   - **`tsVisibleInputModeOrderedArrayKey`** (NOT `tsVisibleInputModeOrderArray` — wrong name silently
     yields zero visible modes and the whole source is dropped) listing the mode id.

3. **An IMKit method registers TWO TIS entries** — a non-selectable container
   (`TISTypeKeyboardInputMethodModeEnabled`) and the selectable input *mode* (`TISTypeKeyboardInputMode`).
   For enable/select, target the entry with **`kTISPropertyInputSourceIsSelectCapable == true`**;
   selecting the container returns **`-50` (paramErr)** and silently no-ops.

4. **First registration usually needs logout/login** (or at least the mode enabled at login) before
   TIS surfaces it. Mid-session `TISRegisterInputSource` returns `0` but will NOT surface a bundle
   that was previously cached as invalid. The installer must detect "registered but not yet listed"
   and tell the user to log out/in once. (A fresh, never-before-seen valid bundle id sidesteps a
   poisoned cache.)

5. **`NSLog` from a TSM-launched IME agent does NOT reliably reach the unified log**, and the agent
   may have a confined `TMPDIR`. For diagnostics, log to a file under the user's home and/or a
   dedicated `os_log` subsystem. (Production: keep a quiet debug log behind a flag.)

6. **Swift 6 isolation:** the project is MainActor-by-default. `IMKInputController`'s ObjC
   initializers are nonisolated, so the subclass must be declared **`nonisolated final class`** (or
   you get "main actor-isolated initializer cannot override a nonisolated declaration"). TSM calls
   the controller on the main thread regardless.

7. **Activation is lazy/bind-on-focus** — see §2. Don't expect `activateServer:` from a bare
   `TISSelectInputSource`.

8. **Consent prompt:** "…wants to activate the third-party input method" appears once on the first
   `TISEnableInputSource` and (in the spike) did not recur in-session after approval. The setup flow
   must expect and explain it.

---

## 4. Build wiring

- New XcodeGen target `RelayInputMethod` (type `application`, `LSUIElement`, ad-hoc signed like the
  rest; `PRODUCT_BUNDLE_IDENTIFIER = com.relay.inputmethod.RelayInputMethod`, its own
  `Info.plist`). Keep its sources isolated (e.g. `Sources/InputMethod/**`, excluded from the `Relay`
  target glob).
- **Embed** the built `RelayInputMethod.app` inside `Relay.app` (a Copy Files build phase into e.g.
  `Contents/Library/InputMethods/` or `Contents/Resources/`) so the installer can copy it out on
  demand. The IME target builds as a dependency of `Relay` for embedding, but is NOT otherwise wired
  into the app's runtime.
- Shared insertion/diff/IPC code can live in a small framework or be compiled into both targets.

---

## 5. Settings / UX flow

- Settings section (under the existing Config UI): a toggle **"Insert via input method (better
  Electron/Chromium support) — experimental"**, default **off**.
- A **mode picker** (segmented control / radio), enabled only when the toggle is on. Persist the
  choice (e.g. `imkEngagementMode: alwaysOn | justInTime`) in the app's config:
  - **Always on (recommended)** — "Relay stays your active input source; no flicker." → `alwaysOn`.
  - **Just-in-time** — "Switches only while dictating; brief menu-bar flash on start." → `justInTime`.
  The selected mode drives which `IMKEngagement` strategy `IMKSwitcher` uses (§2b). Changing the mode
  while enabled re-engages: `alwaysOn` selects the IME now; `justInTime` restores the user's source
  and switches only per dictation.
- State machine for the row:
  - **Not installed** → toggle (or first mode selection) reveals a **"Set up…"** button. Tapping it
    runs `IMKInstaller` (copy → register → enable), shows the consent prompt, and — if TIS doesn't
    list it yet — shows "Log out and back in once to finish setup."
  - **Installed + enabled** → toggle turns IME insertion on/off and the mode picker takes effect;
    Relay launches/keeps-alive/terminates the helper accordingly. In `alwaysOn`, enabling selects the
    IME as the active source; disabling restores the previous source.
  - **"Remove"** affordance → `uninstall` (restore previous source if currently selected, disable the
    source, remove the bundle from `~/Library/Input Methods/`, terminate the helper) + note that a
    logout fully purges it.
- Never install or register anything until the user taps **Set up**.

---

## 6. Verification

- `make build` builds both `Relay` and `RelayInputMethod`; the IME embeds into `Relay.app`.
- Setup from the UI installs + enables; the source appears in System Settings ▸ Keyboard ▸ Input
  Sources.
- With the feature on, a push-to-talk dictation into **Notes** (native) and **Claude desktop /
  VS Code / Slack** (Electron) inserts text with a correct caret; interim text shows underlined and
  finalizes cleanly; the user's previous input source is restored afterward.
- Disabling the feature terminates the helper and stops switching; the AX/paste path still works.
- Secure (password) field → falls back, no hang.

## 7. Risks

- **Distribution signing/notarization:** for a Developer ID build the embedded IME bundle must be
  signed and notarized as part of Relay (deep-sign the nested `.app`); the consent prompt and the
  logout-on-first-install remain. (Ad-hoc/dev builds work as-is.)
- **TSM vs Relay-launched helper** both spawning the bundle — keep the IMKServer connection name
  canonical and the IPC idempotent; prefer Relay as the single launcher.
- **The menu-bar flash** on switch-in (pending the §2 research) — may ship as-is if research finds no
  invisible rebind; the always-on-IME architecture is the escape hatch.
- **macOS version drift** in the Chromium `NSTextInputClient` behavior — pin expectations and re-test
  per major Chrome/Electron bump.

## 8. Acceptance criteria

- [ ] `RelayInputMethod.app` builds, embeds in `Relay.app`, and installs only on explicit user
      action; commits via `insertText:` and passes through keystrokes.
- [ ] Settings toggle + **mode picker (Always-on / Just-in-time)** + "Set up…" flow
      (install/register/enable/consent/logout-guidance) and a remove path.
- [ ] Both engagement modes work behind one swappable `IMKEngagement` strategy: **Always-on** engages
      once with no flash; **Just-in-time** switches per dictation (brief menu-bar flip on start) and
      restores the previous source. Changing the mode at runtime re-engages correctly.
- [ ] Relay launches/keeps-alive/terminates the helper process itself; IPC streams marked/commit
      events from ASR to the helper.
- [ ] Dictation works end-to-end in at least one native and one Electron app in both modes;
      transparent fallback when not installed/enabled or in secure fields.
- [ ] All §3 gotchas honored; builds cleanly.
