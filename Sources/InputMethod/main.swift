import AppKit
import InputMethodKit

// RelayInputMethod — the production IMK helper (plan 08). A thin insertion proxy:
// it owns an IMKServer + IMKInputController and applies setMarkedText:/insertText:
// requests that arrive over CFMessagePort from the main Relay app. No ASR, audio,
// or UI lives here.
//
// Two processes may try to be this helper: TSM spawns it when the IME is the
// selected source, and Relay launches it itself (IMKProcessManager) so it is alive
// in just-in-time mode and to own the lifecycle. The CFMessagePort name is the
// singleton guard — whichever process binds it first wins; the other exits.

IMKLog.write("=== RelayInputMethod starting, argv=\(CommandLine.arguments) ===")

// 1. IPC + singleton guard. If the port is taken, another instance is already the
//    helper; defer to it (TSM will route text to whichever holds the IMKServer).
let ipc = IMKMessagePortServer()
guard ipc.start() else {
    IMKLog.write("another RelayInputMethod instance owns the IPC port — exiting")
    exit(0)
}

// 2. The IMKServer on the connection name from Info.plist (mandatory match only
//    under the sandbox; we are unsandboxed). Held for the process lifetime — if it
//    deallocates, TSM drops the connection.
let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
    ?? IMKMessaging.connectionName
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
IMKLog.write("IMKServer up (connection=\(connectionName), bundle=\(Bundle.main.bundleIdentifier ?? "?"))")
_ = server

// Activate ourselves from our own process — macOS only honors enabling a
// third-party IME when the call originates from the IME's own bundle.
IMKSelfActivation.registerAndEnable()

// 3. Run the event loop (LSUIElement: no Dock icon, no menu).
NSApplication.shared.run()
