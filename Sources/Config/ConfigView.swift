import SwiftUI

/// The four areas of the configuration window.
enum ConfigSection: String, CaseIterable, Identifiable, Hashable {
    case microphone, shortcut, model, history, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .shortcut: return "Shortcut"
        case .model: return "Model"
        case .history: return "History"
        case .general: return "General"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic"
        case .shortcut: return "keyboard"
        case .model: return "waveform"
        case .history: return "clock"
        case .general: return "gearshape"
        }
    }
}

/// Root of the configuration window: a sidebar of sections + a detail pane.
struct ConfigView: View {
    @State private var selection: ConfigSection? = .microphone

    var body: some View {
        NavigationSplitView {
            List(ConfigSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch selection ?? .microphone {
            case .microphone: MicrophoneSection()
            case .shortcut: KeybindSection()
            case .model: ModelStatusSection()
            case .history: HistorySection()
            case .general: GeneralSection()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
