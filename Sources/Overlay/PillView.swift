import SwiftUI

/// The Liquid Glass dictation pill: a live waveform + elapsed timer inside a
/// glass capsule. Purely informational — no buttons, no text transcript.
struct PillView: View {
    var controller: OverlayController

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                WaveformView(levels: controller.levels)
                    .frame(width: 116, height: 24)
                Text(timeString)
                    .font(.system(.callout, design: .rounded).monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(
                .regular.tint(.accentColor.opacity(0.22)).interactive(false),
                in: .capsule
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeString: String {
        let total = Int(controller.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A row of bars whose heights track the rolling level history.
private struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 3
            let barWidth = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(.tint)
                        .frame(width: barWidth, height: height(for: levels[index], in: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func height(for level: Float, in maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 3
        let clamped = CGFloat(max(0, min(1, level)))
        // Gentle curve so quiet input still shows movement.
        let shaped = pow(clamped, 0.7)
        return minHeight + shaped * (maxHeight - minHeight)
    }
}
