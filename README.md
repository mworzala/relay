# Relay

> [!IMPORTANT]  
> Relay is experimental and very much Claude-authored.
> Use at your own risk, and expect no maintenance guarantees. Contributions are welcome.

A native **macOS 26** push-to-talk dictation app. Hold a key (default **Right
Command**), speak, and Relay types what you say into whatever text field is
focused. Live, self-correcting as you talk using NVIDIA **Parakeet v3**
running on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).

> **Requirements:** macOS 26+, Apple Silicon (Parakeet is ANE/arm64-only),
> Xcode 26+. Built and verified on macOS 26.5 / Xcode 26.5 / Swift 6.3.

---

## Quick start

```sh
brew install xcodegen      # one-time, if not already installed
make build                 # generate Relay.xcodeproj + compile (first build also
                           # resolves & compiles FluidAudio — slow once, fast after)
make run                   # build + launch the app
make install               # build + copy the .app to /Applications
```

The Xcode project is **generated** from [`project.yml`](project.yml) and is
git-ignored. Never hand-edit `Relay.xcodeproj`, change `project.yml` and run
`make generate`.

---

## Permissions

Relay needs three things from the user; the first-run wizard requests them:

1. **Microphone** — to capture speech.
2. **Accessibility** — to post synthetic keystrokes (type the text) and read the
   focused field (in keystroke mode).
3. **Input Monitoring** — to read the focused field in Accessibility mode on
   Electron/Chromium apps.

### Why no App Sandbox

Relay injects keystrokes system-wide (`CGEvent`) and reads the global focused UI
element (Accessibility API). The App Sandbox forbids both, so the app is
**intentionally not sandboxed** (see [`Support/Relay.entitlements`](Support/Relay.entitlements)).

Relay will not ship to the app store.

### IMK mode (opt-in)

An optional input-method path ([`IMK/`](Sources/IMK), [`InputMethod/`](Sources/InputMethod))
for apps where keystroke/AX insertion is awkward (Electron/Chromium). When enabled
and activated, dictation streams as a live **underlined composition** and commits a
single authoritative final on release — a clean, single-undo insertion through the
same channel the OS uses for IMEs. It reuses the AX prefix-capture above for
seam unification.

- IPC between the app and the bundled helper is **CFMessagePort** (the helper is
  embedded at `Relay.app/Contents/Library/InputMethods/RelayInputMethod.app`).
- **One-time activation caveat:** a freshly-registered third-party input method
  can't be enabled programmatically on macOS 26 — the user must add it once in
  **System Settings ▸ Keyboard ▸ Input Sources ▸ +** (or log out/in). Relay guides
  this and polls until it's enabled. Default **off**.

### Debug mode (`RELAY_DEBUG`)

```sh
make debug-run         # runs the app with RELAY_DEBUG=1
```

`RELAY_DEBUG=1` turns on two things:

- **Diagnostics strip** above the dictation pill showing the resolved target app,
  the active injection mode (`ax` / `keystroke` / `secure`), whether the
  Electron/Chromium manual-accessibility flip was needed, the caret-prefix length
  (contents are never logged), the last injection op, and the active mic. In **IMK
  mode** it instead shows `mode=imk`, the bound app, the engagement strategy
  (`always-on` / `just-in-time`), the captured prefix length, and the last op. The
  strip is generic — new signals can be appended without changing the view. Hidden
  in normal builds.
- **Injector tracing** — each edit (`NSLog`) from the AX and keystroke injectors.

`RELAY_DEBUG_INJECT=1` is the legacy flag for tracing only (no strip).
