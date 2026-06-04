import SwiftUI

/// Settings for transcript formatting: the ITN (number formatting) toggle and the
/// always-on list of user regex replacement rules. Mirrors MicrophoneSection's
/// mutate-then-`settings.save()` pattern; persistence is driven by `.onChange`.
struct FormattingSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Format numbers, currency & percentages", isOn: $settings.enableITN)
            } header: {
                Text("Number formatting")
            } footer: {
                Text("Converts spoken numbers to written form as you dictate — e.g. \"two hundred fifty\" → 250, \"fifty percent\" → 50%, \"ten dollars\" → $10. Conservative: ambiguous words are left alone.")
                    .font(.caption)
            }

            Section {
                if settings.replacements.isEmpty {
                    Text("No rules yet. Add one to rewrite dictated text — e.g. find \\bgpt\\b, replace GPT.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach($settings.replacements) { $rule in
                        ruleRow($rule)
                    }
                    .onDelete { settings.replacements.remove(atOffsets: $0) }
                }
                Button {
                    settings.replacements.append(TextReplacementRule())
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
            } header: {
                Text("Text replacements")
            } footer: {
                Text("Regular-expression find → replace rules, always applied (after number formatting) in array order. Use $1, $2… for capture groups. An invalid pattern is skipped, never crashing.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Formatting")
        // Persist on any change to the toggle or the rules (add / edit / delete).
        .onChange(of: settings.enableITN) { _, _ in settings.save() }
        .onChange(of: settings.replacements) { _, _ in settings.save() }
    }

    @ViewBuilder
    private func ruleRow(_ rule: Binding<TextReplacementRule>) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Find (regex)", text: rule.pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Replace", text: rule.replacement)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            HStack {
                Toggle("Ignore case", isOn: rule.caseInsensitive)
                Spacer()
                Toggle("Enabled", isOn: rule.enabled)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
