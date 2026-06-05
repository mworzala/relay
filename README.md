# Relay

A native **macOS 26** push-to-talk dictation app. Hold a key (default **Right
Command**), speak, and Relay types what you say into whatever text field is
focused — live, self-correcting as you talk — using NVIDIA **Parakeet v3**
running on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).

A floating **Liquid Glass** pill shows a live waveform + timer while you dictate.
No menu bar item; the app runs in the background and reopens its config window
from the Dock.

> **Requirements:** macOS 26+, Apple Silicon (Parakeet is ANE/arm64-only),
> Xcode 26+. Built and verified on macOS 26.5 / Xcode 26.5 / Swift 6.3.

---

## Quick start

```sh
brew install xcodegen      # one-time, if not already installed
make build                 # generate Relay.xcodeproj + compile (first build also
                           # resolves & compiles FluidAudio — slow once, fast after)
make run                   # build + launch the app
```

`make` targets: `generate` (XcodeGen), `build`, `run`, `launch`, `xcode` (run the
binary in this terminal to see logs), `open` (open in Xcode), `clean`, `reset`.
`./build.sh [target]` wraps the same.

The Xcode project is **generated** from [`project.yml`](project.yml) and is
git-ignored — never hand-edit `Relay.xcodeproj`; change `project.yml` and run
`make generate`.

---

## Permissions

Relay needs three things from the user; the first-run wizard requests them:

1. **Microphone** — to capture speech (`NSMicrophoneUsageDescription`).
2. **Accessibility** — to post synthetic keystrokes (type the text) and read the
   focused field. The wizard calls `AXIsProcessTrustedWithOptions` so Relay
   **registers itself** into the Accessibility list automatically (no `+` button
   needed) and deep-links to the exact pane.
3. **(Maybe) Input Monitoring** — the global hold-to-talk observer uses an
   `NSEvent` global monitor for `.flagsChanged`, which is gated by Accessibility,
   so a *separate* Input Monitoring grant is normally **not** required. If global
   key events don't arrive under Accessibility alone on your build, Relay falls
   back to a listen-only `CGEventTap` and will ask for Input Monitoring. See
   [Hotkey](#architecture).

### ⚠️ Ad-hoc signing + permissions (important caveat)

This project signs **ad-hoc** (`CODE_SIGN_IDENTITY = "-"`, no Developer team) so
you can build it with no Apple Developer account. The trade-off:

- With ad-hoc signing the code signature can **change between rebuilds**, so macOS
  TCC may **drop Relay from the Accessibility/Input-Monitoring lists** and you'll
  have to re-grant after some rebuilds. Relay detects loss of trust at runtime and
  sends you back to the permission step.
- We use a **stable bundle id** (`com.relay.Relay`) and sign consistently to make
  grants persist as well as ad-hoc allows.
- **Fix:** add a **Developer ID** (set `DEVELOPMENT_TEAM` + a Developer ID identity
  in `project.yml`, enable hardened runtime, notarize). That makes permissions
  stick. This is a **config change, not a refactor** — no source edits required.

### Why no App Sandbox

Relay injects keystrokes system-wide (`CGEvent`) and reads the global focused UI
element (Accessibility API). The App Sandbox forbids both, so the app is
**intentionally not sandboxed** (see [`Support/Relay.entitlements`](Support/Relay.entitlements)).
A non-sandboxed app cannot ship on the Mac App Store; distribute via Developer ID
+ notarization instead.

---

## Architecture

SwiftUI app lifecycle (`@main struct RelayApp: App`) with a thin AppKit
`AppDelegate` only where SwiftUI can't reach. Swift 6 with Xcode 26 "approachable
concurrency" (MainActor-isolated by default); the ASR engine and text injector are
`actor`s / serialized contexts to avoid races.

| Folder (`Sources/`) | Responsibility |
| --- | --- |
| `App/` | `RelayApp`, `AppDelegate` (background lifecycle, reopen), activation policy, wiring |
| `Config/` | Settings model + persistence (mic priority, keybind, launch-at-login, first-run flag) |
| `Onboarding/` | First-run wizard (download + permissions) |
| `Audio/` | Mic enumeration, hot-plug priority routing, `AVAudioEngine` capture, level metering |
| `ASR/` | FluidAudio wrapper, model download/status, streaming pipeline (confirmed/volatile) |
| `Injection/` | Synthetic-keystroke injector with backspace-diff tail editing |
| `Hotkey/` | Global passive hold-to-talk detection |
| `Overlay/` | Floating Liquid Glass pill (`NSPanel` + SwiftUI host) |
| `History/` | SwiftData store + history UI |

**Dock vs. background:** default is a normal Dock app. The choice lives in one
place — [`App/ActivationPolicy.swift`](Sources/App/ActivationPolicy.swift). Switch
`.regular` → `.accessory` for a no-Dock app; do **not** add `LSUIElement` to
Info.plist (keeps one source of truth).

See [`docs/INTEGRATION-NOTES.md`](docs/INTEGRATION-NOTES.md) for the verified
FluidAudio v0.15.0 and macOS 26 Liquid Glass API surfaces this app is built on.

### Data locations
- Models: `~/Library/Application Support/Relay/Models/`
- Config + history: SwiftData under `~/Library/Application Support/Relay/`

---

## Known gotchas

- **Secure input fields** (password fields) block synthetic keystrokes by design —
  Relay fails gracefully and types nothing there.
- **Overlay focus:** the pill is a non-activating panel that never becomes key, so
  keystrokes always land in your real text field, not the pill.
- **Device routing:** capture uses `AVCaptureSession` + `AVCaptureDeviceInput`
  resolved by UID, NOT `AVAudioEngine`. `AVAudioEngine.inputNode` realizes against
  and opens the *system default* input device regardless of a later
  `kAudioOutputUnitProperty_CurrentDevice` set — which would (e.g.) open AirPods and
  force a Bluetooth HFP switch even when another mic is selected. `AVCaptureSession`
  opens only the device you hand it. Mid-session disconnect reroutes to the next
  priority device without crashing.
- **Held-modifier injection:** the hold-to-talk key (default Right Command) is down
  the whole time you dictate. CGEvents built from a `.hidSystemState` source inherit
  that live ⌘ flag, which turns injected text into ⌘-shortcuts and Backspace into
  ⌘+Delete (line-delete). The injector therefore clears `event.flags` on every
  posted event so keystrokes are always literal.
- **Electron/browser inputs:** the Accessibility caret-safety check is reliable in
  native Cocoa fields but spotty in Electron/web inputs; it's a safeguard, not a
  guarantee.

---

## How dictation works

Relay uses **LocalAgreement-2** over the full-quality batch Parakeet engine rather
than FluidAudio's `SlidingWindowAsrManager`. The sliding-window manager only emits
on ~11 s chunk boundaries and corrupts text across window seams when the chunk is
shrunk for finer updates; instead Relay keeps a growing 16 kHz buffer and
re-transcribes the whole thing every ~250 ms (cheap at rtfx ≈ 37 on the ANE). Each
hypothesis is internally coherent, so committing the longest word-prefix that two
consecutive hypotheses agree on gives a frozen prefix + a self-correcting volatile
tail with no boundary garbage. On key-up a final full-buffer pass produces the
authoritative transcript, which the injector reconciles on screen and saves to
history. See [`docs/INTEGRATION-NOTES.md`](docs/INTEGRATION-NOTES.md).

## Diagnostics

A headless `relay-asr-probe` CLI target exercises the audio + ASR layers without
the GUI (handy for development):

```sh
make build                                  # builds the probe too
./build/Build/Products/Debug/relay-asr-probe transcribe path/to/audio.wav
./build/Build/Products/Debug/relay-asr-probe stream-file path/to/audio.wav --realtime
./build/Build/Products/Debug/relay-asr-probe list-devices
./build/Build/Products/Debug/relay-asr-probe hotkey-test   # / inject-test / meter-file / capture-test
./build/Build/Products/Debug/relay-asr-probe ax-dump       # focused element's AX text support
```

### Debug mode (`RELAY_DEBUG`)

```sh
make debug-run         # runs the app with RELAY_DEBUG=1
```

`RELAY_DEBUG=1` turns on two things:

- **Diagnostics strip** above the dictation pill showing the resolved target app,
  the active injection mode (`ax` / `keystroke` / `secure`), whether the
  Electron/Chromium manual-accessibility flip was needed, the caret-prefix length
  (contents are never logged), the last injection op, and the active mic. The
  strip is generic — new signals can be appended without changing the view. Hidden
  in normal builds.
- **Injector tracing** — each edit (`NSLog`) from the AX and keystroke injectors.

`RELAY_DEBUG_INJECT=1` is the legacy flag for tracing only (no strip).

## Acceptance checklist

Most of these require granting Microphone + Accessibility (the first-run wizard
walks you through it), so verify them by running the app:

- [ ] With no window open, hold **Right Command** → the glass pill appears
      bottom-center over the focused app (incl. full-screen) with a live waveform +
      timer, without stealing focus.
- [ ] Speaking types text live into the focused field; the tail self-corrects as
      you keep talking while earlier words stay put; releasing finalizes clean text
      and adds it to History.
- [ ] Unplugging the active mic mid-use falls to the next priority device;
      reconnecting switches back.
- [ ] Quitting and relaunching preserves history, mic priority, and keybind.
- [ ] No menu bar item; closing the config window leaves the app running and
      hotkey-active; clicking the Dock icon reopens the window.
