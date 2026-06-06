import AVFoundation
import Observation
import FluidAudio

/// Live transcription via **LocalAgreement-2** over the full-quality batch Parakeet
/// engine, with **adaptive re-inference frequency** to keep CPU bounded.
///
/// We keep the whole utterance buffer and re-transcribe it, committing the
/// word-prefix that two consecutive hypotheses agree on (frozen) while the tail
/// stays volatile. Re-transcribing the *whole* buffer is what makes each
/// hypothesis internally coherent — no window seams, no dedup, no timing-drift
/// artifacts — but doing it at a fixed 250 ms cadence is O(N²) and pegs the CPU.
///
/// So the pass interval scales with the buffer length: short utterances update
/// briskly; as the buffer grows the interval grows too, holding the CPU duty cycle
/// roughly constant (~half a core) no matter how long you talk. On `finish()` a
/// single authoritative full-buffer pass produces the final transcript.
@MainActor
@Observable
final class StreamingTranscriber {
    private(set) var confirmed = ""
    private(set) var volatile = ""
    private(set) var isStreaming = false

    @ObservationIgnored
    var onUpdate: (@MainActor (_ confirmed: String, _ volatile: String) -> Void)?

    @ObservationIgnored private var manager: AsrManager?
    @ObservationIgnored private var language: Language?
    @ObservationIgnored private var decoderLayers = 2
    @ObservationIgnored private var loop: Task<Void, Never>?

    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private var prevWords: [String] = []
    @ObservationIgnored private var confirmedWords: [String] = []   // strictly-growing committed prefix

    /// True while buffering pre-roll audio captured on key-down, before `start`
    /// begins the inference loop.
    @ObservationIgnored private var accepting = false

    private let sampleRate = 16_000
    private let minSamples = 4_800          // ~0.3s before first inference (lower = snappier)
    private let baseIntervalMs = 140        // floor between passes (early updates feel live)
    /// Added per second of buffered audio: keeps (pass time)/(interval) bounded.
    private let intervalPerSecondMs = 60

    /// Begin buffering mic samples **before** inference starts — called on key-down
    /// so the mic hardware warms and the opening words are captured during the arm
    /// delay. `start` then runs the loop over the already-buffered pre-roll.
    func prepare() {
        samples = []
        prevWords = []
        confirmedWords = []
        confirmed = ""
        volatile = ""
        accepting = true
    }

    func start(manager: AsrManager, language: Language? = nil) {
        self.manager = manager
        self.language = language
        if !accepting { samples = [] }   // keep any pre-roll captured during arming
        accepting = false
        prevWords = []
        confirmedWords = []
        confirmed = ""
        volatile = ""
        isStreaming = true
        loop = Task { @MainActor [weak self] in await self?.runLoop() }
    }

    func append(samples16k newSamples: [Float]) {
        guard accepting || isStreaming, !newSamples.isEmpty else { return }
        samples.append(contentsOf: newSamples)
    }

    func finish() async -> String {
        isStreaming = false
        loop?.cancel()
        loop = nil
        guard let manager, samples.count >= minSamples else {
            let fallback = combined()
            reset()
            return fallback
        }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let finalText = (try? await manager.transcribe(samples, decoderState: &state, language: language))?
            .text ?? combined()
        reset()
        return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        isStreaming = false
        loop?.cancel()
        loop = nil
        reset()
    }

    // MARK: - Inference loop

    private func runLoop() async {
        guard let manager else { return }
        decoderLayers = await manager.decoderLayerCount
        while isStreaming {
            let snapshot = samples
            if snapshot.count >= minSamples {
                var state = TdtDecoderState.make(decoderLayers: decoderLayers)
                if let result = try? await manager.transcribe(
                    snapshot, decoderState: &state, language: language) {
                    applyLocalAgreement(to: result.text)
                }
            }
            // Space passes proportionally to buffer length so CPU stays bounded.
            let seconds = Double(max(snapshot.count, minSamples)) / Double(sampleRate)
            let intervalMs = max(baseIntervalMs, Int(seconds * Double(intervalPerSecondMs)))
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
    }

    /// LocalAgreement-2: extend the committed prefix to the longest word-prefix the
    /// last two hypotheses agree on; everything after is volatile.
    private func applyLocalAgreement(to text: String) {
        let curr = Self.words(text)
        let result = LocalAgreement.step(prev: prevWords, curr: curr, confirmed: confirmedWords)
        confirmedWords = result.confirmed
        confirmed = result.confirmed.joined(separator: " ")
        volatile = result.volatile.joined(separator: " ")
        prevWords = curr
        onUpdate?(confirmed, volatile)
    }

    // MARK: - Helpers

    private func combined() -> String {
        [confirmed, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reset() {
        samples = []
        prevWords = []
        confirmedWords = []
        manager = nil
        confirmed = ""
        volatile = ""
        accepting = false
    }

    /// Word split used for LocalAgreement. Delegates to the shared `WordCount`
    /// helper so the streaming definition and the stats word count stay identical.
    /// `nonisolated` (pure) so off-main callers and tests can use it directly.
    nonisolated static func words(_ text: String) -> [String] { WordCount.words(text) }
}
