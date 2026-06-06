import AppKit
import InputMethodKit

/// The production IMK controller. TSM instantiates one per text-input session (the
/// class name comes from `Info.plist` → `InputMethodServerControllerClass`). It is
/// a thin insertion proxy: it records the focused client, applies
/// `setMarkedText:`/`insertText:` requests routed from the main app through
/// `IMKBridge`, and **passes through all ordinary typing** (`handle` returns
/// `false`). No ASR, no audio, no UI — all dictation logic lives in the main app.
///
/// `@objc(RelayInputMethodController)` so IMKServer can instantiate it by the bare
/// name in `Info.plist`. `nonisolated final class` because `IMKInputController`'s
/// ObjC initializers are nonisolated — a MainActor-default subclass can't override
/// them ("main actor-isolated initializer cannot override a nonisolated
/// declaration"). TSM calls these methods on the main thread regardless.
@objc(RelayInputMethodController)
nonisolated final class RelayInputMethodController: IMKInputController {

    /// The focused client for this session, captured from `activateServer:`'s
    /// sender (the verified spike path). Held for the session; cleared on deactivate.
    private var boundClient: IMKTextInput?

    nonisolated override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        IMKLog.write("controller init")
    }

    // TSM binds a focused app's input context to this controller (on a real focus
    // transition — see §2). Record the client and tell the bridge we're engaged.
    nonisolated override func activateServer(_ sender: Any!) {
        assert(Thread.isMainThread, "TSM must call IMKInputController on the main thread")
        super.activateServer(sender)
        bind(sender)
        IMKLog.write("activateServer client=\(boundClient?.bundleIdentifier() ?? "?")")
        IMKBridge.shared.controllerActivated(self)
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        assert(Thread.isMainThread, "TSM must call IMKInputController on the main thread")
        IMKLog.write("deactivateServer")
        IMKBridge.shared.controllerDeactivated(self)
        boundClient = nil
        super.deactivateServer(sender)
    }

    // Pass-through: returning false lets the keystroke reach the client app so
    // ordinary typing is unaffected (verified in the spike). We also opportunistically
    // (re)bind the client here in case activateServer didn't carry a usable one.
    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        assert(Thread.isMainThread, "TSM must call IMKInputController on the main thread")
        if boundClient == nil { bind(sender) }
        return false
    }

    // MARK: - Client binding

    private func bind(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        // Ignore our own helper window — the just-in-time focus-churn briefly makes
        // this process key, and we must not treat that as a real text session.
        if client.bundleIdentifier() == IMKMessaging.helperBundleID { return }
        boundClient = client
    }

    // MARK: - Insertion (called via IMKBridge on the main thread)

    /// The bound client's bundle id, or "" when nothing insertable is bound.
    func clientBundleID() -> String { boundClient?.bundleIdentifier() ?? "" }

    /// Replace the live underlined composition with `text`. Caret sits at the end;
    /// `NSNotFound` replacement range means "the current marked range / caret".
    func setMarked(_ text: String) {
        guard let client = boundClient else { return }
        let length = (text as NSString).length
        client.setMarkedText(text,
                             selectionRange: NSRange(location: length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Commit `text` as final, ending the composition. With an active marked range,
    /// `insertText:` replaces it with `text` (the standard TSM "commit composition"
    /// behavior — this is the channel that lands in Chromium's `ImeCommitText()`).
    func commit(_ text: String) {
        guard let client = boundClient else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Discard the live composition without committing (empty marked text ends it).
    func clearComposition() {
        guard let client = boundClient else { return }
        client.setMarkedText("",
                             selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
