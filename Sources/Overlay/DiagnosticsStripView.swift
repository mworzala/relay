import SwiftUI

/// A compact, monospaced, low-contrast strip of `label:value` chips rendered just
/// above the dictation pill in debug mode. Generic by design: it iterates
/// `diagnostics.fields`, so new signals show up without changing this view.
struct DiagnosticsStripView: View {
    var diagnostics: OverlayDiagnostics

    var body: some View {
        HStack(spacing: 5) {
            ForEach(diagnostics.fields) { field in
                HStack(spacing: 4) {
                    Text(field.label).foregroundStyle(.white.opacity(0.55))
                    Text(field.value).foregroundStyle(.white)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.78), in: .rect(cornerRadius: 5))
            }
        }
        .font(.system(size: 10, design: .monospaced).weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
