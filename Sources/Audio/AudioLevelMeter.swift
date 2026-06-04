import AVFoundation
import Foundation

/// Pure DSP for the waveform overlay: RMS/peak of a buffer and a perceptual
/// 0…1 mapping. Stateless and `nonisolated` so it can run on the realtime audio
/// thread inside the capture tap.
enum AudioLevelMeter {

    /// RMS and peak amplitude (linear, 0…1) of the first channel of a Float32 buffer.
    nonisolated static func levels(from buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        guard let channels = buffer.floatChannelData else { return (0, 0) }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return (0, 0) }
        let samples = channels[0]
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sumSquares += s * s
            peak = max(peak, abs(s))
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        return (min(rms, 1), min(peak, 1))
    }

    /// RMS and peak amplitude (linear, 0…1) of a raw mono Float sample buffer.
    nonisolated static func levels(from samples: [Float]) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var sumSquares: Float = 0
        var peak: Float = 0
        for s in samples {
            sumSquares += s * s
            peak = max(peak, abs(s))
        }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        return (min(rms, 1), min(peak, 1))
    }

    /// Map a linear RMS amplitude to a 0…1 display level on a dB curve (−60 dB
    /// floor) so quiet speech is still visible on the meter/waveform.
    nonisolated static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floorDB: Float = -60
        let clamped = max(floorDB, min(0, db))
        return (clamped - floorDB) / -floorDB
    }
}
