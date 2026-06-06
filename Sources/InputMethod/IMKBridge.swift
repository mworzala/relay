import AppKit
import InputMethodKit

/// Mediates between the per-session `IMKInputController` (which holds the focused
/// client) and the CFMessagePort server (which receives commands from the main
/// app). The controller registers itself here on `activateServer:`; the message
/// server routes `setMarked`/`commit`/`clear` here; we forward to the controller's
/// current client. Pushes `engaged`/`disengaged` events back to the app.
///
/// Everything in the helper runs on the **main thread** — TSM calls the controller
/// on main, and the CFMessagePort source is scheduled on the main run loop — so
/// this single-instance state needs no locking. `@unchecked Sendable` documents
/// that confinement and lets `shared` be a global and be reached from the C callout.
nonisolated final class IMKBridge: @unchecked Sendable {
    static let shared = IMKBridge()
    private init() {}

    /// The controller for the currently-active input session (TSM retains it for
    /// the session lifetime, so a weak ref is safe — we don't own it).
    private weak var controller: RelayInputMethodController?

    /// True between `beginDictation`/`engageJustInTime` and `endDictation`. Commands
    /// are ignored outside that window so a stray late message can't mutate a field.
    private var dictating = false

    /// Pushes events to the app (set by the message-port server once its
    /// remote-to-app port exists). Best-effort; nil before the app connects.
    var eventSink: ((IMKMessaging.Event, String) -> Void)?

    // MARK: - Controller registration (called from the controller, main thread)

    func controllerActivated(_ controller: RelayInputMethodController) {
        self.controller = controller
        let bundle = controller.clientBundleID()
        IMKLog.write("bridge: controller activated, client=\(bundle)")
        eventSink?(.engaged, bundle)
    }

    func controllerDeactivated(_ controller: RelayInputMethodController) {
        // Only clear if it's still the active one (sessions can overlap briefly).
        guard self.controller === controller else { return }
        IMKLog.write("bridge: controller deactivated")
        self.controller = nil
        // A focus change ends the composition implicitly; drop dictation state too.
        dictating = false
        eventSink?(.disengaged, "")
    }

    // MARK: - Engagement (called from the message server, main thread)

    /// Begin accepting marked/commit. Returns the bound client's bundle id, or ""
    /// when nothing insertable is bound (caller falls back to the AX/paste path).
    /// Only arms `dictating` when a client is actually bound, so a no-bind begin
    /// doesn't leave the helper stuck accepting (and dropping) later commands.
    func beginDictation(expecting expectedBundleID: String = "") -> String {
        let bundle = controller?.clientBundleID() ?? ""
        // Stale-bind guard (always-on, no focus-churn): boundClient is cleared only on
        // a real TSM deactivateServer, so if focus moved to a non-text element or an
        // app that didn't re-activate the IME, it can still point at the *previous*
        // field. When the app tells us which app it's targeting and the bound client is
        // a different app, treat the binding as stale and don't arm — the app falls
        // back to AX/paste rather than risk setMarked/commit landing in the old field.
        if !expectedBundleID.isEmpty, !bundle.isEmpty, bundle != expectedBundleID {
            IMKLog.write("bridge: beginDictation stale bound=\(bundle) expected=\(expectedBundleID) — not arming")
            dictating = false
            return ""
        }
        dictating = !bundle.isEmpty
        IMKLog.write("bridge: beginDictation bound=\(bundle.isEmpty ? "<none>" : bundle)")
        return bundle
    }

    func endDictation() {
        IMKLog.write("bridge: endDictation")
        controller?.clearComposition()
        dictating = false
    }

    // MARK: - Insertion (called from the message server, main thread)

    func setMarked(_ text: String) {
        guard dictating else { return }
        controller?.setMarked(text)
    }

    func commit(_ text: String) {
        guard dictating else { return }
        controller?.commit(text)
    }

    func clear() {
        guard dictating else { return }
        controller?.clearComposition()
    }
}
