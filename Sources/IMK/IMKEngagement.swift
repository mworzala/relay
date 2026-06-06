import Carbon
import Foundation

/// Remembers the input source that was current before Relay's IME took over, so it
/// can be restored. Captured at different moments per mode (enable-time for
/// always-on, per-dictation for just-in-time), so it lives here, shared by the
/// strategy and `IMKController`.
final class IMKSourceMemory {
    var previous: TISInputSource?
}

/// The one swappable engage/disengage strategy (plan §2b). Both modes share all the
/// install/IPC/insertion machinery and differ only in **when** Relay's IME is the
/// active source. Selected at runtime from `AppSettings.imkEngagementMode`.
protocol IMKEngagement {
    /// Engage globally when the feature is enabled.
    func activate(memory: IMKSourceMemory)
    /// Disengage globally when the feature is disabled.
    func deactivate(memory: IMKSourceMemory)
    /// Per-dictation engage. Returns the bound client's bundle id ("" = nothing
    /// insertable bound → caller falls back to AX/paste). `targetBundleID` is the
    /// app the dictation is aimed at, used to reject a stale always-on binding.
    func beginDictation(targetPID: pid_t, targetBundleID: String,
                        ipc: IMKMessagePortClient, memory: IMKSourceMemory) -> String
    /// Per-dictation end.
    func endDictation(ipc: IMKMessagePortClient, memory: IMKSourceMemory)
}

/// **Always on** (recommended, flash-free): select Relay's IME once on enable and
/// leave it the full-time source. The IME binds to fields on the user's *own* focus
/// changes — no churn, no menu-bar flip. Each dictation just toggles the helper's
/// internal dictation gate; it's already bound to the focused field.
struct AlwaysOnEngagement: IMKEngagement {
    /// Helper replies instantly (no churn), so a short ceiling is plenty.
    private static let beginTimeout: CFTimeInterval = 0.3

    func activate(memory: IMKSourceMemory) {
        // Capture the user's current source once (don't overwrite if we re-activate
        // while already current, which would memo our own source as "previous").
        if !IMKSwitcher.isOursCurrent() {
            memory.previous = IMKSwitcher.currentSource()
        }
        IMKSwitcher.selectOurs()
    }

    func deactivate(memory: IMKSourceMemory) {
        IMKSwitcher.restore(memory.previous)
        memory.previous = nil
    }

    func beginDictation(targetPID: pid_t, targetBundleID: String,
                        ipc: IMKMessagePortClient, memory: IMKSourceMemory) -> String {
        // Pass the target bundle id so the helper can reject a stale binding to a
        // previously-focused field (always-on does no focus-churn to refresh it).
        ipc.request(.beginDictation, targetBundleID, timeout: Self.beginTimeout) ?? ""
    }

    func endDictation(ipc: IMKMessagePortClient, memory: IMKSourceMemory) {
        ipc.post(.endDictation)
    }
}

/// **Just in time** (opt-in, one menu-bar flip per dictation start): Relay isn't the
/// full-time source. Each dictation captures the current source, selects ours, and
/// has the helper perform the focus-churn to engage; on end it restores the previous
/// source (free, no churn).
struct JustInTimeEngagement: IMKEngagement {
    /// The helper does the ~0.65 s focus-churn before replying; this is a safety
    /// ceiling, not the expected wait (~2.3× the measured churn).
    private static let engageTimeout: CFTimeInterval = 1.5

    func activate(memory: IMKSourceMemory) {}   // not the full-time source

    // A safety net: if the app quits while a just-in-time switch is somehow still in
    // effect, restore the user's source rather than strand them on Relay's IME.
    func deactivate(memory: IMKSourceMemory) {
        IMKSwitcher.restore(memory.previous)
        memory.previous = nil
    }

    func beginDictation(targetPID: pid_t, targetBundleID: String,
                        ipc: IMKMessagePortClient, memory: IMKSourceMemory) -> String {
        // targetBundleID is unused here: the focus-churn forces the target app key and
        // (re)binds the client fresh, so there's no stale-binding window to guard.
        memory.previous = IMKSwitcher.currentSource()
        guard IMKSwitcher.selectOurs() else { return "" }
        let bound = ipc.request(.engageJustInTime, String(targetPID), timeout: Self.engageTimeout) ?? ""
        // CRITICAL: if we selected our IME but nothing bound (helper unresponsive,
        // churn failed, no insertable field), restore the user's source NOW — the
        // caller falls back to AX/paste and will never call endDictation for this
        // session, so this is the only chance to avoid stranding them on Relay's IME.
        if bound.isEmpty {
            IMKSwitcher.restore(memory.previous)
            memory.previous = nil
        }
        return bound
    }

    func endDictation(ipc: IMKMessagePortClient, memory: IMKSourceMemory) {
        ipc.post(.endDictation)
        IMKSwitcher.restore(memory.previous)
        memory.previous = nil
    }
}
