import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import FluidAudio

// relay-asr-probe — headless diagnostics for Relay's audio + ASR layers,
// independent of the GUI. Subcommands:
//
//   relay-asr-probe transcribe <audio-file>   download Parakeet v3 + transcribe
//   relay-asr-probe list-devices              enumerate Core Audio input devices
//   relay-asr-probe meter-file <audio-file>   run the level meter DSP over a file
//
// Exit code 0 on success, 1 on failure, 2 on bad usage.

func errLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let arguments = CommandLine.arguments
let subcommand = arguments.count >= 2 ? arguments[1] : "help"

switch subcommand {

case "list-devices":
    let devices = CoreAudioDevices.inputDevices()
    print("Input devices (\(devices.count)):  [✓ = resolves to an AVCaptureDevice for routing]")
    var allResolved = true
    for device in devices {
        let resolved = CaptureDeviceResolver.device(forUID: device.uid) != nil
        if !resolved { allResolved = false }
        print("  \(resolved ? "✓" : "✗") \(device.name)  [uid=\(device.uid)]")
    }
    if let defaultUID = CoreAudioDevices.defaultInputUID() {
        print("default input uid: \(defaultUID)")
    }
    print(allResolved ? "UID-MAPPING: all devices resolvable" : "UID-MAPPING: some devices NOT resolvable")
    exit(devices.isEmpty ? 1 : 0)

case "meter-file":
    guard arguments.count >= 3 else { errLine("usage: relay-asr-probe meter-file <file>"); exit(2) }
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2]))
        let format = file.processingFormat   // Float32, non-interleaved
        let chunk: AVAudioFrameCount = 1024
        var peakLevel: Float = 0
        var chunks = 0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            let rms = AudioLevelMeter.levels(from: buffer).rms
            peakLevel = max(peakLevel, AudioLevelMeter.normalizedLevel(rms: rms))
            chunks += 1
        }
        print(String(format: "meter-file: %d chunks, peak normalized level = %.3f", chunks, peakLevel))
        exit(peakLevel > 0 ? 0 : 1)
    } catch {
        errLine("ERROR: \(error)")
        exit(1)
    }

case "transcribe":
    guard arguments.count >= 3 else { errLine("usage: relay-asr-probe transcribe <file>"); exit(2) }
    let audioPath = arguments[2]
    print("relay-asr-probe transcribe")
    print("Model directory: \(ParakeetModel.directory.path)")
    print("Already downloaded: \(ParakeetModel.isDownloaded())")
    fflush(stdout)
    do {
        let start = Date()
        let models = try await ParakeetModel.downloadAndLoad(progress: { progress in
            switch progress.phase {
            case .listing:
                print("  listing files… \(Int(progress.fractionCompleted * 100))%")
            case .downloading(let done, let total):
                print("  downloading \(done)/\(total) — \(Int(progress.fractionCompleted * 100))%")
            case .compiling(let name):
                print("  compiling \(name)")
            }
            fflush(stdout)
        })
        print("Models ready in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        fflush(stdout)

        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(
            URL(fileURLWithPath: audioPath), decoderState: &state, language: nil)

        print("=== TRANSCRIPT ===")
        print(result.text)
        print("=== METRICS ===")
        print("rtfx=\(result.rtfx) confidence=\(result.confidence) "
            + "duration=\(String(format: "%.2f", result.duration))s "
            + "processing=\(String(format: "%.2f", result.processingTime))s")
        await asr.cleanup()
        exit(0)
    } catch {
        errLine("ERROR: \(error)")
        exit(1)
    }

case "stream-file":
    // usage: stream-file <file> [--realtime]
    guard arguments.count >= 3 else {
        errLine("usage: relay-asr-probe stream-file <file> [--realtime]"); exit(2)
    }
    let audioPath = arguments[2]
    let realtime = arguments.contains("--realtime")
    print("relay-asr-probe stream-file (LocalAgreement-2, realtime=\(realtime))")
    fflush(stdout)
    do {
        let models = try await ParakeetModel.downloadAndLoad()
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let samples = try AudioConverter().resampleAudioFile(path: audioPath)
        print("Loaded \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16_000))s @ 16kHz)")
        fflush(stdout)

        let probeStart = Date()
        var updateCount = 0
        var lastConfirmed = ""
        var confirmedRegressions = 0   // committed text that shrank/changed prefix (bad for injection)
        let transcriber = StreamingTranscriber()
        transcriber.onUpdate = { confirmed, volatile in
            updateCount += 1
            if !confirmed.hasPrefix(lastConfirmed) && !lastConfirmed.hasPrefix(confirmed) {
                confirmedRegressions += 1   // prefix changed (not a clean grow)
            } else if confirmed.count < lastConfirmed.count {
                confirmedRegressions += 1   // shrank
            }
            lastConfirmed = confirmed
            let t = String(format: "%5.1fs", Date().timeIntervalSince(probeStart))
            print("[\(t)] confirmed(\(confirmed.count)): …\(confirmed.suffix(36))  ||  vol: \(volatile.suffix(46))")
            fflush(stdout)
        }
        transcriber.start(manager: asr)

        let chunk = 8_000   // ~0.5s at 16 kHz
        var index = 0
        while index < samples.count {
            let slice = Array(samples[index..<min(index + chunk, samples.count)])
            transcriber.append(samples16k: slice)
            index += chunk
            if realtime { try? await Task.sleep(for: .seconds(0.5)) }
        }

        let streamedConfirmed = lastConfirmed
        let final = await transcriber.finish()
        print("=== updates: \(updateCount)  committed-regressions: \(confirmedRegressions) (want 0) ===")
        print("=== STREAMED COMMITTED (live confirmed, before final pass) ===")
        print(streamedConfirmed)
        print("=== FINAL (authoritative full-buffer pass) ===")
        print(final)
        exit(final.isEmpty ? 1 : 0)
    } catch {
        errLine("ERROR: \(error)")
        exit(1)
    }

case "inject-test":
    // Verify TextDiff produces correct, minimal edits across a streaming-like
    // sequence (including a lowercase→Capitalized correction).
    let sequence = [
        "Welcome",
        "Welcome to",
        "Welcome to relay",
        "Welcome to Relay,",
        "Welcome to Relay, a push",
        "Welcome to Relay, a push to talk",
        "Welcome to Relay, a push to talk dictation",
    ]
    var buffer = ""
    var totalBackspaces = 0
    var totalInserted = 0
    var ok = true
    for target in sequence {
        let plan = TextDiff.plan(typed: buffer, target: target)
        totalBackspaces += plan.backspaces
        totalInserted += plan.insert.count
        buffer = TextDiff.apply(plan, to: buffer)
        if buffer != target { print("MISMATCH: \"\(buffer)\" != \"\(target)\""); ok = false; break }
    }
    let naiveInsert = sequence.dropFirst().reduce(0) { $0 + $1.count }
    print("inject-test: final=\"\(buffer)\" backspaces=\(totalBackspaces) inserted=\(totalInserted) (naive retype=\(naiveInsert))")
    print(ok && buffer == sequence.last ? "INJECT-TEST: PASS" : "INJECT-TEST: FAIL")
    exit(ok && buffer == sequence.last ? 0 : 1)

case "capture-test":
    // Exercise the AVAudioEngine tap on the realtime audio thread to confirm the
    // @Sendable fix (no MainActor isolation trap). Needs mic permission to capture
    // real audio; without it the engine may fail to start (reported, not crashed).
    let seconds = arguments.count >= 3 ? (Double(arguments[2]) ?? 2.0) : 2.0
    let device = CoreAudioDevices.inputDevices().first
    print("capture-test on \(device?.name ?? "default") for \(seconds)s")
    let engine = AudioCaptureEngine()
    do {
        try engine.start(deviceUID: device?.uid) { @Sendable _ in }
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(250))
            print(String(format: "  level=%.3f", engine.level))
        }
        engine.stop()
        print("CAPTURE-TEST: OK (tap ran without isolation trap)")
        exit(0)
    } catch {
        errLine("capture start failed (likely mic permission for a CLI): \(error)")
        exit(0)
    }

case "tokens":
    // Inspect how Parakeet token timings map to words (needed to trim the
    // streaming re-inference buffer at word boundaries).
    guard arguments.count >= 3 else { errLine("usage: relay-asr-probe tokens <file>"); exit(2) }
    do {
        let models = try await ParakeetModel.downloadAndLoad()
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let samples = try AudioConverter().resampleAudioFile(path: arguments[2])
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        print("TEXT: \(result.text)")
        let timings = result.tokenTimings ?? []
        print("TOKENS (\(timings.count)):")
        for t in timings.prefix(50) {
            // Show the raw token string with visible delimiters to see word markers.
            print("  |\(t.token)|  [\(String(format: "%.2f", t.startTime))–\(String(format: "%.2f", t.endTime))]")
        }
        exit(0)
    } catch { errLine("ERROR: \(error)"); exit(1) }

case "hotkey-test":
    // Verify HotkeyMatcher decodes bare-modifier (Right Command) press/release.
    var matcher = HotkeyMatcher(keybind: .rightCommand)
    func name(_ t: HotkeyMatcher.Transition?) -> String { t.map { "\($0)" } ?? "nil" }
    let r1 = matcher.handleFlagsChanged(keyCode: 54, flags: [.command])   // press
    let r2 = matcher.handleFlagsChanged(keyCode: 54, flags: [])           // release
    let r3 = matcher.handleFlagsChanged(keyCode: 54, flags: [.command])   // press
    let r4 = matcher.handleFlagsChanged(keyCode: 54, flags: [])           // release
    let r5 = matcher.handleFlagsChanged(keyCode: 55, flags: [.command])   // nil (Left Cmd)
    print("rcmd down:", name(r1))
    print("rcmd up:  ", name(r2))
    print("rcmd down:", name(r3))
    print("rcmd up:  ", name(r4))
    print("lcmd down:", name(r5), "(should be nil)")

    var combo = HotkeyMatcher(keybind: Keybind(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue, isBareModifier: false))
    let c1 = combo.handleKeyDown(keyCode: 49, flags: [.command])          // press (⌘Space)
    let c2 = combo.handleKeyUp(keyCode: 49, flags: [.command])            // release
    let c3 = combo.handleKeyDown(keyCode: 49, flags: [.option])           // nil (wrong mod)
    print("combo ⌘Space down:", name(c1))
    print("combo ⌘Space up:  ", name(c2))
    print("combo ⌥Space down:", name(c3), "(should be nil)")

    let ok = r1 == .press && r2 == .release && r3 == .press && r4 == .release && r5 == nil
        && c1 == .press && c2 == .release && c3 == nil
    print(ok ? "HOTKEY-TEST: PASS" : "HOTKEY-TEST: FAIL")
    exit(ok ? 0 : 1)

case "ax-dump":
    // Inspect the system-focused element's AX text support: app identity, value
    // length, selection range, and settability — a headless way to see whether a
    // given app will get AX injection or the keystroke fallback. Read-only; never
    // writes. Requires Accessibility permission, and a bare CLI is usually NOT a
    // trusted AX client, so this commonly reports "no element". Run the GUI app's
    // probe path for real per-app inspection.
    guard AXIsProcessTrusted() else {
        print("ax-dump: this process is NOT trusted for Accessibility.")
        print("  Grant it in System Settings ▸ Privacy & Security ▸ Accessibility")
        print("  (CLIs generally can't be trusted; use the app for live testing).")
        exit(1)
    }
    guard let element = AXFocus.focusedElement() else {
        print("ax-dump: no system-focused element (nothing focused, or not permitted).")
        exit(1)
    }
    AXText.setTimeout(element)
    let id = AXText.appIdentity(of: element)
    let value = AXText.value(of: element)
    let count = AXText.characterCount(of: element)
    let sel = AXText.selectedRange(of: element)
    let settableSelText = AXText.isSettable(element, kAXSelectedTextAttribute as String)
    let settableValue = AXText.isSettable(element, kAXValueAttribute as String)
    let supports = AXText.supportsTextEditing(element)
    print("ax-dump:")
    print("  app:           \(id.name ?? "—")  [\(id.bundleID ?? "?")]  pid=\(id.pid)")
    print("  value length:  \(value?.utf16.count.description ?? count?.description ?? "—") (UTF-16)")
    print("  selection:     \(sel.map { "loc=\($0.location) len=\($0.length)" } ?? "—")")
    print("  settable:      selectedText=\(settableSelText) value=\(settableValue)")
    print("  AX-injectable: \(supports ? "YES (would use AX mode)" : "no (keystroke fallback)")")
    exit(0)

default:
    errLine("usage: relay-asr-probe <transcribe <file> | stream-file <file> [--realtime] | list-devices | meter-file <file> | hotkey-test | ax-dump>")
    exit(2)
}
