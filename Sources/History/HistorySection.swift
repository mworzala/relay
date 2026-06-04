import SwiftUI
import SwiftData

/// Transcription history: newest first, each row with copy + remove. Includes a
/// small manual-add field so add/copy/remove can be exercised before the ASR
/// pipeline exists (M2 acceptance).
struct HistorySection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Transcription.timestamp, order: .reverse) private var items: [Transcription]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Add a transcription…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if items.isEmpty {
                ContentUnavailableView(
                    "No transcriptions yet",
                    systemImage: "text.bubble",
                    description: Text("Dictations you record will appear here, newest first.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        HistoryRow(item: item, onRemove: { remove(item) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .navigationTitle("History")
    }

    private func addDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        context.insert(Transcription(text: text))
        try? context.save()
        draft = ""
    }

    private func remove(_ item: Transcription) {
        context.delete(item)
        try? context.save()
    }
}

private struct HistoryRow: View {
    let item: Transcription
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .textSelection(.enabled)
                    .lineLimit(4)
                Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                Clipboard.copy(item.text)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from history")
        }
        .padding(.vertical, 4)
    }
}
