import CoreFoundation
import Foundation

/// The main app's side of the CFMessagePort channel to the helper. Sends commands
/// to the helper's `toHelperPortName` and vends a local `toAppPortName` for the
/// helper's engaged/disengaged events.
///
/// `nonisolated` + `@unchecked Sendable`, mirroring the app's other off-main
/// helpers: in practice every caller is the main actor (DictationController renders,
/// the settings UI, IMKController), and the event-receiving port source is scheduled
/// on the main run loop, so the CF ports are effectively main-confined. The `onEvent`
/// sink hops to the main actor itself (the established debug-sink pattern).
///
/// Replies use a send that pumps a **private** run-loop mode
/// (`CFMessagePortSendRequest` with a dedicated reply mode): while awaiting the
/// reply only that mode's reply source is serviced — the app's other run-loop
/// sources (the global hotkey monitor, timers, the helper-event port) are NOT
/// re-entered, so a key-release during the just-in-time focus-churn can't re-enter
/// the dictation state machine. The wait blocks the main thread for the churn
/// (~0.65 s, JIT only; the pill isn't shown until after the engage) — a deliberate
/// trade of a brief, invisible block for a re-entrancy-free state machine. The
/// always-on path returns in well under a millisecond.
nonisolated final class IMKMessagePortClient: @unchecked Sendable {
    private var remotePort: CFMessagePort?
    private var localPort: CFMessagePort?
    private var localSource: CFRunLoopSource?
    private var onEvent: (@Sendable (IMKMessaging.Event, String) -> Void)?

    /// Send timeout for a `request` (the helper receives immediately when healthy).
    private static let requestSendTimeout: CFTimeInterval = 0.3
    /// Short send timeout for fire-and-forget streaming posts, so a congested/dead
    /// helper can't stall the main thread on every ASR update — a dropped marked
    /// update is harmless (the next one supersedes it).
    private static let postSendTimeout: CFTimeInterval = 0.05
    /// A private run-loop mode for reply waits — nothing else is registered in it,
    /// so the wait never re-enters other sources. (A `String`; bridged to `CFString`
    /// at the call site so it stays `Sendable` as a static.)
    private static let replyMode = "com.relay.imk.reply"

    // MARK: - Outbound (app → helper)

    /// Fire-and-forget command (setMarked/clear/endDictation).
    func post(_ command: IMKMessaging.Command, _ payload: String = "") {
        guard let remote = remote() else { return }
        let status = CFMessagePortSendRequest(
            remote, command.rawValue, IMKMessaging.data(payload) as CFData,
            Self.postSendTimeout, /* rcvTimeout */ 0, /* replyMode */ nil, /* returnData */ nil)
        if status != Int32(kCFMessagePortSuccess) { remotePort = nil }
    }

    /// Command expecting a reply (ping/beginDictation/engageJustInTime/commit). Waits
    /// in a private run-loop mode until the reply or `timeout`. Returns nil on
    /// transport failure/timeout, or the reply string (possibly empty) on success.
    @discardableResult
    func request(_ command: IMKMessaging.Command, _ payload: String = "",
                 timeout: CFTimeInterval) -> String? {
        guard let remote = remote() else { return nil }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote, command.rawValue, IMKMessaging.data(payload) as CFData,
            Self.requestSendTimeout, timeout, Self.replyMode as CFString, &reply)
        guard status == Int32(kCFMessagePortSuccess) else {
            remotePort = nil
            return nil
        }
        guard let data = reply?.takeRetainedValue() else { return "" }
        return IMKMessaging.string(data as Data)
    }

    /// Liveness probe — true if the helper answered.
    func isHelperResponding() -> Bool {
        request(.ping, timeout: 0.3) == "ok"
    }

    private func remote() -> CFMessagePort? {
        if let port = remotePort, CFMessagePortIsValid(port) { return port }
        remotePort = CFMessagePortCreateRemote(nil, IMKMessaging.toHelperPortName as CFString)
        return remotePort
    }

    // MARK: - Inbound (helper → app) event listener

    /// Vend the app's local port for helper events and route them to `onEvent`
    /// (which hops to the main actor). Idempotent.
    func startEventListener(onEvent: @escaping @Sendable (IMKMessaging.Event, String) -> Void) {
        self.onEvent = onEvent
        guard localPort == nil else { return }

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callout: CFMessagePortCallBack = { _, msgid, data, info in
            guard let info else { return nil }
            let client = Unmanaged<IMKMessagePortClient>.fromOpaque(info).takeUnretainedValue()
            if let event = IMKMessaging.Event(rawValue: msgid) {
                client.onEvent?(event, IMKMessaging.string(data as Data?))
            }
            return nil
        }

        guard let port = CFMessagePortCreateLocal(
            nil, IMKMessaging.toAppPortName as CFString, callout, &context, nil)
        else { return }
        localPort = port
        if let source = CFMessagePortCreateRunLoopSource(nil, port, 0) {
            localSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// Tear down both ports (feature disabled / app quitting). Removes the run-loop
    /// source before invalidating so repeated enable/disable cycles don't leak it.
    func stop() {
        if let source = localSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        localSource = nil
        if let port = localPort { CFMessagePortInvalidate(port) }
        localPort = nil
        remotePort = nil
        onEvent = nil
    }
}
