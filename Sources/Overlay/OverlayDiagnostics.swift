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
    /// Latest IMK snapshot, pushed from the dictation controller while a session is
    /// routed through the input method. Takes precedence over `injection` in the
    /// strip (the AX/keystroke coordinator never runs in IMK mode).
    private(set) var imk: IMKDebugInfo?
    /// Active microphone device name, pulled from a source each overlay tick.
    var micName: String?

    /// Apply a fresh injection snapshot (called on the main actor).
    func applyInjection(_ info: InjectionDebugInfo) { injection = info }

    /// Apply a fresh IMK snapshot (called on the main actor).
    func applyIMK(_ info: IMKDebugInfo) { imk = info }

    /// Forget the last session's injection/IMK info (so a new session doesn't briefly
    /// show the previous app/mode before the live path republishes).
    func resetInjection() { injection = nil }
    func resetIMK() { imk = nil }

    struct Field: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Ordered `label:value` pairs for the strip. **Append new signals here** —
    /// the view renders whatever this returns. In IMK mode we deliberately show only
    /// the IMK-relevant signals (no AX-only fields like `manual-ax`).
    var fields: [Field] {
        var out: [Field] = []
        if let m = imk {
            out.append(.init(label: "mode", value: "imk"))
            out.append(.init(label: "app", value: m.appName))
            out.append(.init(label: "engage", value: m.engagement))
            out.append(.init(label: "prefix", value: "\(m.prefixLength)"))
            out.append(.init(label: "op", value: m.lastOp))
        } else if let i = injection {
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

/// A snapshot of the IMK insertion path's state for the debug diagnostics strip,
/// pushed from `DictationController` while a dictation is routed through the input
/// method. Mirrors `InjectionDebugInfo` but carries only IMK-relevant signals.
/// `prefixLength` is a *count only* — the prefix contents are never carried here.
nonisolated struct IMKDebugInfo: Sendable, Equatable {
    var appName: String
    /// The engagement strategy in effect ("always-on" / "just-in-time").
    var engagement: String
    var prefixLength: Int
    var lastOp: String
}
