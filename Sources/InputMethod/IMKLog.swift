import Foundation
import os

/// File + os_log diagnostics for the helper. `NSLog` from a TSM-launched
/// input-method agent does not reliably surface in the unified log, and such an
/// agent may run with a redirected `TMPDIR`, so we write to an absolute path in the
/// user's home (we are unsandboxed) AND emit to a dedicated `os_log` subsystem,
/// queryable with:
///   log show --last 5m --predicate 'subsystem == "com.relay.inputmethod"' --info
///
/// Quiet by default; set `RELAY_IMK_DEBUG=1` in the helper's environment to also
/// append to `~/relay-inputmethod.log`. (os_log is always emitted — it's cheap and
/// off unless someone is watching.)
nonisolated enum IMKLog {
    static let oslog = OSLog(subsystem: "com.relay.inputmethod", category: "helper")
    static let path = NSHomeDirectory() + "/relay-inputmethod.log"
    static let fileEnabled = ProcessInfo.processInfo.environment["RELAY_IMK_DEBUG"] == "1"

    static func write(_ msg: @autoclosure () -> String) {
        let message = msg()
        os_log("%{public}@", log: oslog, type: .default, message)
        guard fileEnabled else { return }

        let line = "\(Date()) [pid \(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        let data = Data(line.utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: data)
            return
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
    }
}
