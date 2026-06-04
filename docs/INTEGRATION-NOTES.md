# Integration notes — verified API surfaces

These are the **real** symbols verified against the installed SDK (macOS 26.5,
Xcode 26.5) and **FluidAudio v0.15.0** source. Do not guess against these — they
were read from source / the SDK `.swiftinterface`, not from memory.

## macOS 26 Liquid Glass (SwiftUI / SwiftUICore)

The glass modifiers live in **SwiftUICore** but are re-exported by `import SwiftUI`.

| Symbol | Signature |
| --- | --- |
| `glassEffect(_:in:)` | `func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View` |
| `GlassEffectContainer` | `init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content)` |
| `glassEffectID(_:in:)` | `func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View` |
| `glassEffectTransition(_:)` | `func glassEffectTransition(_ transition: GlassEffectTransition) -> some View` |
| `glassEffectUnion(id:namespace:)` | merges adjacent glass shapes |
| `struct Glass` | `.regular`, `.clear`, `.identity`, `.tint(Color?)`, `.interactive(Bool = true)` |
| `GlassEffectTransition` | `.matchedGeometry`, `.materialize`, `.identity` |
| `GlassButtonStyle` / `.glass` | `Button { } .buttonStyle(.glass)` (and `.glassProminent`) |

Pill usage: `GlassEffectContainer { content.glassEffect(.regular.tint(...).interactive(false), in: .capsule) }`.

## FluidAudio v0.15.0 — Parakeet v3 ASR

One module: `import FluidAudio`. **Apple Silicon only** (Parakeet throws
`ASRError.unsupportedPlatform` on Intel). Parakeet TDT types carry no `@available`
gate, so they work on the macOS 14 baseline and on macOS 26.

### Models: download / load / custom directory
- `AsrModels.downloadAndLoad(to: URL? = nil, configuration: MLModelConfiguration? = nil, version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8, progressHandler: DownloadUtils.ProgressHandler? = nil) async throws -> AsrModels`
- `AsrModels.download(to:force:version:encoderPrecision:progressHandler:) async throws -> URL` (download only)
- `AsrModels.load(from: URL, ...) async throws -> AsrModels` (already downloaded)
- `AsrModels.modelsExist(...)`, `AsrModels.defaultCacheDirectory(for:) -> URL`
- **v3 is the default** everywhere; identifier maps `AsrModelVersion.v3 -> Repo.parakeetV3 = "FluidInference/parakeet-tdt-0.6b-v3-coreml"`.
- Default cache: `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`.
- **GOTCHA (custom dir):** the `to:`/`from:` URL is treated as a *path whose last
  component is stripped* and then `repo.folderName` (`parakeet-tdt-0.6b-v3`) is
  re-appended. To land models under `~/Library/Application Support/Relay/Models/`,
  pass `…/Relay/Models/parakeet-tdt-0.6b-v3` (mirroring `defaultCacheDirectory`'s
  shape). **Verify the real on-disk path empirically in milestone 3** and adjust.
- Progress: `DownloadUtils.ProgressHandler = @Sendable (DownloadProgress) -> Void`,
  `DownloadProgress{ fractionCompleted: Double, phase: DownloadPhase }`,
  `DownloadPhase = .listing | .downloading(completedFiles,totalFiles) | .compiling(modelName)`.
  Called on an **unspecified queue** → hop to `@MainActor` before touching UI.
- `DownloadUtils.enforceOffline: Bool` (set once at startup) blocks all network.
- Errors: model loading throws `AsrModelsError`; transcription throws `ASRError`.

### Batch transcription
```swift
let models = try await AsrModels.downloadAndLoad(to: relayModelDir, version: .v3,
    encoderPrecision: .int8, progressHandler: { p in /* hop to MainActor */ })
let asr = AsrManager(config: .default)        // actor
try await asr.loadModels(models)
var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount) // 2 for v3
let result = try await asr.transcribe(url, decoderState: &state, language: nil) // or [Float]/AVAudioPCMBuffer
// result: ASRResult{ text, confidence, duration, processingTime, tokenTimings?, rtfx }
```
- `transcribe` overloads: `[Float]` (must ALREADY be 16 kHz mono Float32 — not
  resampled), `AVAudioPCMBuffer` (auto-converted), `URL` (auto-loaded+converted).
- `decoderState` is `inout` (hold in a `var`); fresh state per independent utterance.
- Min input ~300 ms (`ASRConstants.minimumAudioDurationSeconds`); shorter → `ASRError.invalidAudioData`.

### Streaming with confirmed/volatile split (this is our "LocalAgreement")
`SlidingWindowAsrManager` (actor) is the **only** ASR surface that splits
committed vs tentative text. (The `StreamingAsrManager` protocol / EOU / Nemotron
engines expose a single rolling partial with **no** confirmed/volatile split.)

```swift
let cfg = SlidingWindowAsrConfig.default // or .streaming; tune confirmationThreshold + minContextForConfirmation
let stream = SlidingWindowAsrManager(config: cfg)
try await stream.loadModels(models)                 // reuse the same AsrModels
try await stream.startStreaming(source: .microphone)
Task { for await u in await stream.transcriptionUpdates {  // SlidingWindowTranscriptionUpdate
    // u.text, u.isConfirmed (true=committed prefix, false=volatile tail), u.confidence, u.tokenTimings
}}
await stream.streamAudio(buffer)                    // fire-and-forget; resampled internally
let committed = await stream.confirmedTranscript    // append-only, never retracted
let tail      = await stream.volatileTranscript
let finalText = try await stream.finish()           // drains + returns merged final transcript
```
- **GOTCHA:** confirmed text is **append-only / never rolls back**, and confirmation
  needs `minContextForConfirmation` seconds of audio + `confidence >= confirmationThreshold`.
  It is a confidence heuristic, *not* literal LocalAgreement-2 prefix intersection —
  but it satisfies the spec's "use the confirmed/volatile split if FluidAudio exposes one."
- Must consume `transcriptionUpdates` from a Task before/while feeding audio or updates drop.
- For best final accuracy the spec wants a **final full-buffer batch pass** — we keep
  our own raw 16 kHz buffer and run `AsrManager.transcribe([Float])` on key-up, then
  reconcile the tail. (We may run our own AsrManager in parallel rather than rely solely
  on the sliding window.)

### Audio conversion (do NOT hand-roll)
- `AudioConverter()` (stateless, `Sendable`, default target 16 kHz mono Float32):
  - `resampleBuffer(_ AVAudioPCMBuffer) throws -> [Float]` — live mic buffers (any format).
  - `resampleAudioFile(path: String) / (_ url: URL) throws -> [Float]` — file load for batch/test.
  - `resample(_ [Float], from: Double) throws -> [Float]` — known-rate samples.
- `ASRConstants.sampleRate = 16000`, `maxModelSamples = 240_000` (~15 s), min ~0.3 s.

### Compute units
- Default `.cpuAndNeuralEngine` (ANE) via `MLModelConfigurationUtils.defaultConfiguration`;
  preprocessor pinned to `.cpuOnly`. Override by passing a custom `MLModelConfiguration`.
