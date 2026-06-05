# Plan 6 — Input Method Kit spike (does an IMK commit land in Electron?)

> **For the implementing agent.** Self-contained task brief; you have no memory of
> the conversation that produced it. This repo is **Relay**, a macOS 26 push-to-talk
> dictation app (Swift 6, Xcode 26 MainActor-by-default isolation, XcodeGen from
> `project.yml`).
>
> **Read first:** [`docs/text-injection-research.md`](../text-injection-research.md)
> §1 (IMK mechanics, the pass-through answer, the real blockers, programmatic
> enable/select) and §5 (open questions #1, #4, #5, #6, #7). This plan exists to
> resolve those open questions empirically.

## Goal

A **throwaway spike** — NOT a production feature — that answers the linchpin question
the IMK direction hinges on (research §5 #1): **does an Input Method Kit
`insertText:replacementRange:` commit actually land in a Chromium/Electron
contenteditable** (Slack, VS Code, Discord, Claude desktop)? And, secondarily,
measure the operational frictions (enable/select consent prompt, switch latency each
way, the input-source HUD) that determine whether a "switch to our IM only during
dictation, then switch back" design is viable.

Deliverable: a **go/no-go findings doc** (`docs/imk-spike-findings.md`) with a
per-app result matrix. The spike code is disposable and **must not** be wired into
the shipping app.

## Why

IMK is the only insertion path that goes through the **native NSTextInputClient/TSM
channel Chromium implements for IME input** (`insertText:replacementRange:` →
Chromium `ImeCommitText()` → Blink editor — research §1), so it should land text
where our AX writes are inert, with a correct caret and **no Accessibility
permission**. But the end-to-end "IMK → Chromium contenteditable" hop is a strong
**inference, not a quoted fact** (research §1, §5 #1). It is also operationally heavy
(separate signed bundle, a flaky activation-consent prompt, ~150 ms switch latency).
Before anyone designs a production IMK feature we need to *prove the hop* and
*measure the friction* cheaply.

## Design

### 1. Minimal input-method bundle (new, isolated target)

A barebones IMKit input method as a **separate XcodeGen target** (e.g.
`RelayIMSpike.app`), unsandboxed/ad-hoc-signed like the main app, installed into
`~/Library/Input Methods/`. Per research §1 it needs:

- An `IMKServer` created at launch on a connection named **exactly**
  `$(PRODUCT_BUNDLE_IDENTIFIER)_Connection` (only mandatory if sandboxed; the spike
  is unsandboxed, so any documented name works — but follow the convention).
- An `IMKInputController` subclass that:
  - on `activateServer:` (or a debug hotkey) **commits a fixed test string**
    (e.g. `"RELAY_IMK_OK "`) via
    `[sender insertText:@"RELAY_IMK_OK " replacementRange:NSMakeRange(NSNotFound, 0)]`;
  - returns **NO** from `handleEvent:client:` / `inputText:client:` so normal typing
    passes through (research §1 — the pass-through answer);
  - optionally exercises `setMarkedText:selectionRange:replacementRange:` to see if a
    live composition underline appears in each target app.
- Info.plist keys: `InputMethodConnectionName`, `InputMethodServerControllerClass`,
  `InputMethodServerDelegateClass` (optional), `ComponentInputModeDict` →
  `tsInputModeListKey` with one mode, `LSUIElement = YES` (background-only),
  `LSBackgroundOnly`/`LSMinimumSystemVersion` as needed. Model on the ensan-hcl
  `macOS_IMKitSample_2021` and Squirrel `Info.plist` (URLs in research §1).
- Code-sign ad-hoc (`CODE_SIGN_IDENTITY = "-"`) like the other targets.

### 2. Activation harness

A tiny menu/CLI affordance (in the spike app, or a `relay-asr-probe imk` subcommand)
that performs the **switch-on-dictation** sequence and records what happens:

1. `TISRegisterInputSource` the installed bundle (if not already known).
2. `TISEnableInputSource` our source; note whether the **"X wants to activate the
   third-party input method"** consent prompt appears, and whether a logout/login was
   required before the source became visible (research §1, §5 #6).
3. Capture the **current** input source (`TISCopyCurrentKeyboardInputSource`).
4. `TISSelectInputSource(ours)` with the **macism-style nudge** (a tiny temporary
   window + a ~150 ms settle — `TISSelectInputSource` alone is unreliable, research
   §1). Time how long until the switch actually takes effect.
5. Trigger the `insertText:` commit into the currently-focused field.
6. `TISSelectInputSource(previous)` to switch back; time the **switch-back** latency
   (research §5 #5 — unquantified).
7. Note whether the near-cursor **input-source HUD/flag** appeared on the
   *programmatic* switch (research §5 #4 — untested).

Keep timings configurable. Log everything to stdout and to the findings doc.

### 3. Test matrix → findings doc

Run the harness with the focus in each target and fill `docs/imk-spike-findings.md`:

| App | Commit landed? | Caret correct after? | Marked-text preview? | Notes |
|---|---|---|---|---|
| TextEdit (native) | | | | control |
| Safari (WebKit) | | | | |
| Slack (Electron) | | | | the key case |
| VS Code (Electron) | | | | |
| Discord (Electron) | | | | |
| Claude desktop (Electron) | | | | |
| Terminal | | | | |

Also record: did the activation consent prompt appear / recur? forward & back switch
latency (ms)? HUD shown? did secure-input (a password field) suspend it? Finish with
an explicit **GO / NO-GO** recommendation for a production IMK feature, and if GO, the
follow-on questions (full-field reads are NOT solved by IMK — research §1).

### 4. Build wiring

- New `project.yml` target for the spike (append-only — see Parallel execution). Do
  **not** add it to the main `Relay` scheme's dependencies; it builds independently.
- Nothing in `Sources/Injection/**` or the main app changes.

## Parallel execution & file ownership

The **most isolated** of the three parallel plans — ideal to run concurrently.

- **OWNS (all new):** the spike target's sources, its `Info.plist`, the findings doc.
- **Only shared file:** `project.yml` — **append a new target stanza** (don't edit the
  `Relay` or `relay-asr-probe` stanzas). Plan 5 also edits `project.yml` (adds a
  source to `relay-asr-probe`); these touch different stanzas and merge cleanly if
  each keeps its edit local.
- No overlap with Plan 5 or Plan 7's source edits.

## Files

**New**
- Spike target sources: `IMKInputController` subclass + `main`/principal class.
- The spike's `Support/` `Info.plist` (+ entitlements if needed).
- `docs/imk-spike-findings.md` — the results matrix + GO/NO-GO.

**Changed**
- `project.yml` — append the spike target (isolated stanza).

## Edge cases & risks (time-box this)

- **The hop may simply fail** in some Electron apps — that's a valid, valuable result.
- **Consent prompt** is flaky/recurring; **install may need logout/login** (research
  §1) — record it, don't fight it.
- **Secure input** suspends third-party IMEs — expect password fields to be a no-op.
- **Full-field reads are not solved by IMK** — don't scope-creep into reads; this
  spike is about the *commit* hop + activation friction only.
- **Don't destabilize Relay:** the spike is a separate target, never imported by the
  app. If `TISEnableInputSource` pollutes the user's input-source list, document the
  manual cleanup (remove the bundle from `~/Library/Input Methods/`, re-login).

## Verification

- The findings doc's matrix is filled from real runs on a macOS 26 machine with the
  spike installed.
- `make build` builds both the app and the spike target cleanly.
- A clear GO/NO-GO statement with the measured latencies and the per-app landing
  results.

## Acceptance criteria

- [ ] A buildable, installable minimal IMK bundle that commits a test string via
      `insertText:replacementRange:` and passes through keystrokes (returns NO).
- [ ] A harness that enables/selects/deselects the source with the macism nudge and
      records the consent prompt, switch latencies, and HUD behavior.
- [ ] `docs/imk-spike-findings.md` with the per-app landing matrix and a GO/NO-GO.
- [ ] Zero changes to shipping injection code; spike target is isolated.
- [ ] Builds cleanly.

## Out of scope

- Any production IMK feature, UI, onboarding, or notarization — this is a spike.
- Full-field **reads** via IMK (architecturally limited — research §1).
- Marked-text live-preview as a shipped feature (record whether it *works*, but don't
  build the feature).
