import Observation

/// Backing model for the debug **diagnostics strip** shown above the dictation
/// pill. Deliberately generic: it exposes an *ordered list of labeled fields* that
/// the view iterates, so any subsystem can contribute a signal without touching the
/// view — adding a future metric is one more `Field` in `fields`.
///
/// MainActor `@Observable`: the off-main injection coordinator publishes into it by
/// hopping to the main actor.
@MainActor
@Observable
final class OverlayDiagnostics {
    /// Latest injection decision/op snapshot, pushed from the coordinator.
    private(set) var injection: InjectionDebugInfo?
    /// Active microphone device name, pulled from a source each overlay tick.
    var micName: String?

    /// Apply a fresh injection snapshot (called on the main actor).
    func applyInjection(_ info: InjectionDebugInfo) { injection = info }

    /// Forget the last session's injection info (so a new session doesn't briefly
    /// show the previous app/mode before the coordinator republishes).
    func resetInjection() { injection = nil }

    struct Field: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Ordered `label:value` pairs for the strip. **Append new signals here** —
    /// the view renders whatever this returns.
    var fields: [Field] {
        var out: [Field] = []
        if let i = injection {
            out.append(.init(label: "app", value: i.appName))
            out.append(.init(label: "mode", value: i.mode.rawValue))
            out.append(.init(label: "manual-ax", value: i.neededManualAccessibility ? "on" : "off"))
            out.append(.init(label: "prefix", value: "\(i.prefixLength)"))
            out.append(.init(label: "op", value: i.lastOp))
        }
        if let micName, !micName.isEmpty {
            out.append(.init(label: "mic", value: micName))
        }
        return out
    }
}
