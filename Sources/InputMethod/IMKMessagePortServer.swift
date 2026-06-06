import CoreFoundation
import Foundation

/// The helper's IPC endpoint. Vends a local CFMessagePort (`toHelperPortName`) that
/// the main app sends commands to, dispatching each to `IMKBridge`, and lazily
/// holds a remote port back to the app (`toAppPortName`) for pushing engaged/
/// disengaged events.
///
/// Doubles as the **singleton guard** (plan §1b / risk): `CFMessagePortCreateLocal`
/// returns nil if the name is already taken, so a second helper instance (e.g. one
/// TSM spawns while Relay already launched one) detects the conflict in `start()`
/// and exits, leaving a single process to own both the IPC port and the IMKServer.
///
/// `@unchecked Sendable`: the port + cached remote are CF types confined to the
/// main run loop (where the port source is scheduled and the callout fires).
nonisolated final class IMKMessagePortServer: @unchecked Sendable {
    private var localPort: CFMessagePort?
    private var remoteToApp: CFMessagePort?

    /// Create the local port and schedule it on the main run loop. Returns false if
    /// the port name is taken (another helper instance owns it) — caller should exit.
    func start() -> Bool {
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callout: CFMessagePortCallBack = { _, msgid, data, info in
            guard let info else { return nil }
            let server = Unmanaged<IMKMessagePortServer>.fromOpaque(info).takeUnretainedValue()
            return server.handle(msgid: msgid, data: data as Data?)
        }

        // Bind the port. A nil result means the name is taken — usually a live
        // instance (defer to it), but it can also be a port a just-crashed instance
        // hasn't had reclaimed yet, so retry briefly before giving up.
        var port: CFMessagePort?
        for attempt in 0..<3 {
            port = CFMessagePortCreateLocal(nil, IMKMessaging.toHelperPortName as CFString,
                                            callout, &context, nil)
            if port != nil { break }
            if attempt < 2 {
                IMKLog.write("ipc: port \(IMKMessaging.toHelperPortName) taken, retry \(attempt + 1)/3")
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        guard let port else {
            IMKLog.write("ipc: local port \(IMKMessaging.toHelperPortName) is taken — another instance running")
            return false
        }
        localPort = port

        guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            IMKLog.write("ipc: failed to create run loop source")
            return false
        }
        // Scheduled on the main run loop for the helper's process lifetime (the
        // process exits via NSApplication; the run loop releases the source then).
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        // Push engaged/disengaged events to the app through our cached remote port.
        IMKBridge.shared.eventSink = { [weak self] event, payload in
            self?.send(event: event, payload: payload)
        }
        IMKLog.write("ipc: serving on \(IMKMessaging.toHelperPortName)")
        return true
    }

    // MARK: - Inbound (app → helper), main run loop

    private func handle(msgid: Int32, data: Data?) -> Unmanaged<CFData>? {
        guard let command = IMKMessaging.Command(rawValue: msgid) else {
            IMKLog.write("ipc: unknown command msgid=\(msgid)")
            return nil
        }
        let payload = IMKMessaging.string(data)
        switch command {
        case .ping:
            return reply("ok")
        case .beginDictation:
            // Payload (when present) is the app's target bundle id, used to reject a
            // stale always-on binding to a previously-focused field.
            return reply(IMKBridge.shared.beginDictation(expecting: payload))
        case .engageJustInTime:
            FocusChurn.perform(targetPID: pid_t(payload) ?? 0)
            return reply(IMKBridge.shared.beginDictation())
        case .setMarked:
            IMKBridge.shared.setMarked(payload); return nil
        case .commit:
            // Acked so the app can be sure the final text was applied before any
            // just-in-time source restore (messages on one port are FIFO, so the ack
            // also guarantees a preceding setMarked was processed).
            IMKBridge.shared.commit(payload); return reply("ok")
        case .clear:
            IMKBridge.shared.clear(); return nil
        case .endDictation:
            IMKBridge.shared.endDictation(); return nil
        }
    }

    /// Build a reply CFData. The system takes ownership and releases it after send,
    /// so hand over a +1 retain.
    private func reply(_ string: String) -> Unmanaged<CFData> {
        Unmanaged.passRetained(IMKMessaging.data(string) as CFData)
    }

    // MARK: - Outbound (helper → app), best-effort

    private func send(event: IMKMessaging.Event, payload: String) {
        if remoteToApp == nil || !(remoteToApp.map(CFMessagePortIsValid) ?? false) {
            remoteToApp = CFMessagePortCreateRemote(nil, IMKMessaging.toAppPortName as CFString)
        }
        guard let remote = remoteToApp else { return }   // app not listening yet — fine
        let status = CFMessagePortSendRequest(
            remote, event.rawValue, IMKMessaging.data(payload) as CFData,
            /* sendTimeout */ 0.5, /* rcvTimeout */ 0.0, /* replyMode */ nil, /* returnData */ nil)
        if status != Int32(kCFMessagePortSuccess) {
            remoteToApp = nil   // drop a dead port; recreated on next send
        }
    }
}
