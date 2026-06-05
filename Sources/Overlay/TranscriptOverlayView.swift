import SwiftUI

/// The caret-anchored live-transcript box for "Overlay + paste" mode: a compact
/// glass card showing the committed text at full strength and the volatile tail
/// de-emphasized. Purely informational and click-through — the field is never
/// touched until the user releases and the text is pasted.
struct TranscriptOverlayView: View {
    var controller: TranscriptOverlayController

    /// Cap the card width; long transcripts wrap and truncate from the *head* so the
    /// most recent words (the tail the user is speaking) stay visible.
    private static let maxWidth: CGFloat = 440
    private static let lineLimit = 3

    var body: some View {
        let segments = controller.segments
        Group {
            if segments.isEmpty {
                // Nothing yet — keep the panel invisible (no empty-card flash).
                Color.clear.frame(width: 1, height: 1)
            } else {
                GlassEffectContainer {
                    transcript(segments)
                        .font(.system(.body, design: .rounded))
                        .lineLimit(Self.lineLimit)
                        .truncationMode(.head)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Self.maxWidth, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .glassEffect(
                            .regular.tint(.accentColor.opacity(0.18)).interactive(false),
                            in: .rect(cornerRadius: 16)
                        )
                        .accessibilityElement()
                        .accessibilityLabel(Text(segments.combined))
                }
            }
        }
        // Bottom-leading: the card sits at the panel's bottom-left and grows upward
        // as more lines arrive, so the controller can seat that corner just above
        // the caret.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func transcript(_ segments: TranscriptSegments) -> Text {
        Text(segments.head)
            .foregroundColor(.primary)
        + Text(segments.tail)
            .foregroundColor(.secondary)
            .italic()
    }
}
