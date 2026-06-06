import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Picks an injection strategy per dictation session and forwards renders to it.
///
/// On `beginSession` it resolves the focused element, probes AX text capability
/// (coaxing Electron/Chromium via the manual-accessibility flip when needed),
/// captures a bounded caret prefix, and chooses **AX** (primary) or **keystrokes**
/// (fallback) — or nothing under secure input. It applies prefix unification to
/// every render and publishes an `InjectionDebugInfo` snapshot for the overlay.
///
/// `nonisolated` + `@unchecked Sendable`: AX probing and forwarding run off-main
/// on a single serial `queue`.
nonisolated final class InjectionCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.relay.injection-coordinator")
    private let ax = AXTextInjector()
    private let keystroke = KeystrokeTextInjector()
    private let debugSink: (@Sendable (InjectionDebugInfo) -> Void)?

    /// Max UTF-16 units of caret prefix to read. Bounded, and **sensitive**: its
    /// contents are never logged — only its length.
    private static let prefixLimit = 256
    /// Bounded re-probes after the Electron/Chromium manual-accessibility flip,
    /// which builds the AX tree asynchronously. Off-main, only the first session
    /// per app launch pays this (the private keys persist process-lifetime).
    private static let manualAXProbeAttempts = 8
    private static let manualAXProbeInterval: TimeInterval = 0.05   // ≤400ms total, off-main

    // --- Session state, only touched on `queue` ---
    private var active: TextInjecting?
    private var mode: InjectionMode = .keystroke
    private var context = InjectionContext(element: nil)
    /// The last raw (pre-unify) target, so a mid-session AX→keystroke handoff can
    /// re-issue it without waiting for the next streaming render.
    private var lastTarget: String?

    private static let tracing = RelayDebug.injectTracing

    init(debugSink: (@Sendable (InjectionDebugInfo) -> Void)? = nil) {
        self.debugSink = debugSink
    }

    // MARK: Session lifecycle (called by the dictation controller)

    func beginSession() {
        queue.async { self.startSession() }
    }

    func render(_ target: String) {
        queue.async {
            self.lastTarget = target
            guard let active = self.active else { return }
            active.render(self.unify(target))
        }
    }

    func finalize(_ finalText: String) {
        queue.async {
            self.lastTarget = finalText
            guard let active = self.active else { return }
            active.finalize(self.unify(finalText))
            self.active = nil
            self.mode = .keystroke
        }
    }

    /// Resolve the focused text element (running the same Electron/Chromium
    /// manual-accessibility flip a real session would) and read the bounded caret
    /// prefix + next char — **without** installing an injection strategy.
    ///
    /// Used by the IMK path: the input method does its own inserting, but reuses our
    /// prefix unification so a new dictation reads naturally after the text a previous
    /// one committed (spacing/capitalization across the seam). Runs off-main; the
    /// completion fires on the coordinator's serial queue, so the caller hops to its
    /// own actor. `prefix` is `nil` when no AX caret is readable → callers unify
    /// against nil, i.e. insert verbatim (graceful no-op, today's IMK behavior).
    func capturePrefix(completion: @escaping @Sendable (_ prefix: String?, _ nextChar: Character?, _ appName: String) -> Void) {
        queue.async {
            if IsSecureEventInputEnabled() { completion(nil, nil, self.frontmostName()); return }
            let resolved = self.resolveTextTarget()
            guard resolved.usable, let element = resolved.element else {
                completion(nil, nil, resolved.appName)
                return
            }
            let ctx = Self.readCaretContext(element: element)
            self.trace("IMK prefix capture app=\(resolved.appName) caret=\(ctx.caret) prefixLen=\(ctx.prefix?.utf16.count ?? 0)")
            completion(ctx.prefix, ctx.nextChar, resolved.appName)
        }
    }

    /// Unify the dictation with the frozen caret prefix (spacing/dedup/
    /// capitalization). Returns the dictation verbatim in keystroke/no-prefix mode,
    /// where `context.prefix` is nil.
    private func unify(_ target: String) -> String {
        PrefixUnifier.unify(prefix: context.prefix, dictation: target, nextChar: context.nextChar)
    }

    // MARK: Strategy selection

    private func startSession() {
        active = nil
        mode = .keystroke
        lastTarget = nil
        context = InjectionContext(element: nil)

        // 1. Secure input (e.g. a password field) → inject nothing.
        if IsSecureEventInputEnabled() {
            mode = .secure
            publish(base(appName: frontmostName(), mode: .secure, manual: false, prefixLength: 0))
            trace("secure input — injecting nothing")
            return
        }

        let r = resolveTextTarget()
        if r.usable, let element = r.element, let identity = r.identity {
            beginAX(element: element, identity: identity, appName: r.appName, manual: r.manual)
        } else {
            beginKeystroke(element: r.element, appName: r.appName, pid: r.pid, manual: r.manual)
        }
    }

    /// The focused text element resolved for a session, with the metadata both the
    /// injection strategies and the IMK prefix-capture need.
    private struct ResolvedTarget {
        var element: AXUIElement?
        var identity: AXText.AppIdentity?
        var appName: String
        var manual: Bool
        var usable: Bool
        var pid: pid_t
    }

    /// Resolve the frontmost app's focused text element, coaxing Chromium/Electron
    /// via the manual-accessibility flip when there's no usable element yet. Shared
    /// by `startSession` (which then installs a strategy) and `capturePrefix` (which
    /// only reads). Runs on `queue`; the manual-AX retry sleeps are off-main.
    private func resolveTextTarget() -> ResolvedTarget {
        // Resolve the frontmost app up front — we need its pid for the
        // manual-accessibility flip even when the focused element can't be resolved.
        // Electron/Chromium expose NO system-wide focused element until their AX
        // tree is built, which is exactly what the flip triggers.
        let front = NSWorkspace.shared.frontmostApplication
        let frontPid = front?.processIdentifier ?? 0
        let frontName = front?.localizedName ?? "—"

        var element = AXFocus.focusedElement()
        element.map { AXText.setTimeout($0) }
        var identity = element.map { AXText.appIdentity(of: $0) }
        var usable = element.map { AXText.supportsTextEditing($0) } ?? false
        var manual = false
        traceProbe("probe", element, appName: identity?.name ?? frontName,
                   bundleID: identity?.bundleID ?? front?.bundleIdentifier)

        // No usable focused text element (incl. nil)? Flip manual accessibility on
        // the frontmost app — Chromium/Electron build their AX tree only after this,
        // and the keys are a harmless no-op elsewhere — then re-resolve the focused
        // element. The tree builds ASYNCHRONOUSLY, so retry over a short bounded
        // window (off-main; finishes before the first ASR hypothesis arrives).
        if !usable, frontPid != 0 {
            let pid = identity?.pid ?? frontPid
            let flipped = AXText.enableManualAccessibility(pid: pid)
            if flipped {
                for _ in 0..<Self.manualAXProbeAttempts where !usable {
                    Thread.sleep(forTimeInterval: Self.manualAXProbeInterval)
                    // Chromium/Electron expose the focused control on the APP element
                    // (system-wide focus stays nil for web content); try that first.
                    if let re = AXText.focusedElement(ofApp: pid) ?? AXFocus.focusedElement() {
                        element = re
                        AXText.setTimeout(re)
                        identity = AXText.appIdentity(of: re)
                        usable = AXText.supportsTextEditing(re)
                    }
                }
            }
            manual = usable   // record the flip only when it actually unlocked AX
            trace("manual-accessibility flip pid=\(pid) set=\(flipped) → usable=\(usable)")
            traceProbe("re-probe", element, appName: identity?.name ?? frontName,
                       bundleID: identity?.bundleID ?? front?.bundleIdentifier)
        }

        let appName = identity?.name ?? identity?.bundleID ?? frontName
        return ResolvedTarget(element: element, identity: identity, appName: appName,
                              manual: manual, usable: usable, pid: identity?.pid ?? frontPid)
    }

    /// Read the bounded caret prefix + the char just past the caret/selection from a
    /// resolved element. Shared by the AX strategy setup and the IMK prefix capture.
    /// **Sensitive:** the prefix contents are never logged — only its length.
    private static func readCaretContext(element: AXUIElement) -> (prefix: String?, nextChar: Character?, caret: Int) {
        let selection = AXText.selectedRange(of: element)
        let caret = selection?.location ?? (AXText.value(of: element)?.utf16.count ?? 0)
        // The prefix ends at the selection start; the next char is whatever survives
        // PAST the selection (its end), so dictate-over-selection reads the right
        // trailing char, not the soon-replaced first selected char.
        let caretEnd = selection.map { $0.location + $0.length } ?? caret
        return (readPrefix(element: element, caret: caret),
                readNextChar(element: element, caret: caretEnd),
                caret)
    }

    private func beginAX(element: AXUIElement, identity: AXText.AppIdentity, appName: String, manual: Bool) {
        let (prefix, nextChar, caret) = Self.readCaretContext(element: element)
        let prefixLength = prefix?.utf16.count ?? 0   // UTF-16, matching the read window

        let info = base(appName: appName, mode: .ax, manual: manual, prefixLength: prefixLength)
        publish(info)

        context = InjectionContext(
            element: element, pid: identity.pid, bundleID: identity.bundleID,
            appName: appName, caretLocation: caret, prefix: prefix, nextChar: nextChar,
            report: reporter(base: info), fallback: makeFallback())
        active = ax
        mode = .ax
        ax.beginSession(context: context)
        trace("AX mode app=\(appName) caret=\(caret) prefixLen=\(prefixLength)")
    }

    private func beginKeystroke(
        element: AXUIElement?, appName: String, pid: pid_t, manual: Bool,
        prefix: String? = nil, nextChar: Character? = nil
    ) {
        let info = base(appName: appName, mode: .keystroke, manual: manual,
                        prefixLength: prefix?.utf16.count ?? 0)
        publish(info)
        context = InjectionContext(
            element: element, pid: pid, appName: appName,
            prefix: prefix, nextChar: nextChar, report: reporter(base: info))
        active = keystroke
        mode = .keystroke
        keystroke.beginSession(context: context)
        trace("keystroke fallback app=\(appName)")
    }

    /// Re-route the session to the keystroke fallback after the AX strategy's first
    /// write failed (nothing was inserted, so this is a clean retry). Reuses the
    /// same focused element, **preserves the captured caret prefix** so spacing/caps
    /// against existing text still apply, and re-issues the last target.
    private func makeFallback() -> @Sendable () -> Void {
        { [weak self] in self?.queue.async { self?.fallbackToKeystroke() } }
    }

    private func fallbackToKeystroke() {
        guard mode == .ax else { return }
        trace("AX first write failed — re-routing to keystroke fallback")
        beginKeystroke(element: context.element, appName: context.appName, pid: context.pid,
                       manual: false, prefix: context.prefix, nextChar: context.nextChar)
        if let last = lastTarget { active?.render(unify(last)) }
    }

    // MARK: Bounded prefix reads (sensitive — contents never logged)

    private static func readPrefix(element: AXUIElement, caret: Int) -> String? {
        guard caret > 0 else { return "" }   // caret at field start → empty prefix (known)
        let start = max(0, caret - prefixLimit)
        return AXText.string(of: element, in: NSRange(location: start, length: caret - start))
    }

    private static func readNextChar(element: AXUIElement, caret: Int) -> Character? {
        // Prefer a 2-unit read so a surrogate pair (emoji / astral letter) composes
        // into a real Character instead of decoding to U+FFFD; `.first` still yields
        // the single leading grapheme for a BMP char. Fall back to 1 unit when only
        // one (BMP) char remains before end-of-field, where the 2-unit range is out
        // of bounds. Nil at end-of-field → no trailing space (correct).
        if let s = AXText.string(of: element, in: NSRange(location: caret, length: 2)), let c = s.first {
            return c
        }
        if let s = AXText.string(of: element, in: NSRange(location: caret, length: 1)), let c = s.first {
            return c
        }
        return nil
    }

    // MARK: Debug publishing

    private func base(appName: String, mode: InjectionMode, manual: Bool, prefixLength: Int) -> InjectionDebugInfo {
        InjectionDebugInfo(appName: appName, mode: mode,
            neededManualAccessibility: manual, prefixLength: prefixLength, lastOp: "—")
    }

    private func publish(_ info: InjectionDebugInfo) {
        debugSink?(info)
    }

    /// A per-session reporter that stamps the immutable session `base` with each
    /// new last-op string. `@Sendable`: invoked from the strategies' own queues.
    private func reporter(base: InjectionDebugInfo) -> (@Sendable (String) -> Void)? {
        guard let sink = debugSink else { return nil }
        return { op in sink(base.with(lastOp: op)) }
    }

    // MARK: Diagnostics

    private func frontmostName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
    }

    private func trace(_ message: @autoclosure () -> String) {
        if Self.tracing { NSLog("Relay/inject-coord: \(message())") }
    }

    /// Dump the AX text-capability probe for the focused element (no field
    /// contents) so per-app AX support can be diagnosed under RELAY_DEBUG. The
    /// element may be nil (e.g. Electron before its AX tree is built).
    private func traceProbe(_ label: String, _ element: AXUIElement?, appName: String, bundleID: String?) {
        guard Self.tracing else { return }
        guard let element else {
            NSLog("Relay/inject-coord: \(label) app=\(appName) bundle=\(bundleID ?? "?") element=nil")
            return
        }
        let sel = AXText.selectedRange(of: element)
        let selText = AXText.isSettable(element, kAXSelectedTextAttribute as String)
        let value = AXText.isSettable(element, kAXValueAttribute as String)
        NSLog("Relay/inject-coord: \(label) app=\(appName) bundle=\(bundleID ?? "?") "
            + "selRange=\(sel.map { "\($0.location),\($0.length)" } ?? "nil") "
            + "settable[selText=\(selText) value=\(value)]")
    }
}
