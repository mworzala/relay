import Foundation

/// The wire contract shared by the main Relay app and the embedded
/// `RelayInputMethod` helper. Compiled into **both** targets (Relay picks it up by
/// glob; the helper lists this one file explicitly in `project.yml`), so it must
/// stay dependency-free (Foundation only) and `nonisolated`.
///
/// Transport is **CFMessagePort**, not NSXPC: two unsandboxed `.app`s with no
/// launchd registration can reliably vend/discover a global CFMessagePort by name
/// (the PopClip/Bartender pattern), whereas `NSXPCListener(machServiceName:)`
/// without a launchd `MachServices` entry is unreliable. Messages are a verb
/// (`msgid`) plus a UTF-8 payload; short commands stream low-latency over the
/// kernel Mach call. The protocol is intentionally tiny and idempotent so a helper
/// restart is survivable.
nonisolated enum IMKMessaging {
    /// Variant suffix (".dev" for the Debug/dev build, "" for Release/installed),
    /// read from the bundle's `RelayVariantSuffix` Info.plist value (set per build
    /// configuration). Every identity below is suffixed by it so the dev and
    /// installed copies register **distinct** input sources and talk over **distinct**
    /// CFMessagePort channels — they never cross-wire. Both the app and the helper
    /// read it from their own bundles, so they compute identical names per variant.
    private static let variantSuffix: String =
        (Bundle.main.object(forInfoDictionaryKey: "RelayVariantSuffix") as? String) ?? ""

    /// The helper bundle id. MUST contain `.inputmethod.` as an interior label or
    /// the login-time input-source scanner silently ignores the bundle (gotcha §3).
    static let helperBundleID = "com.relay.inputmethod.RelayInputMethod" + variantSuffix

    /// The input *mode* id (its `TISInputSourceID`) — the selectable entry. Mirrors
    /// the bundle id, matching the verified spike's `ComponentInputModeDict`.
    static let inputSourceID = helperBundleID

    /// The `IMKServer` connection name. By convention `<bundleid>_Connection`; the
    /// helper's `Info.plist` `InputMethodConnectionName` reads back this exact value.
    static let connectionName = helperBundleID + "_Connection"

    /// CFMessagePort the **helper** vends and the app sends commands to.
    static let toHelperPortName = helperBundleID + ".toHelper"

    /// CFMessagePort the **app** vends and the helper sends events to.
    static let toAppPortName = "com.relay.Relay" + variantSuffix + ".fromHelper"

    /// Filename the helper is installed under in `~/Library/Input Methods/`. The
    /// embedded payload keeps a stable name (`RelayInputMethod.app`, for the Xcode
    /// copy phase), but it's installed under a variant-suffixed wrapper name so the
    /// dev and installed copies don't overwrite each other there. TIS keys on the
    /// bundle id inside, not the wrapper name, so renaming the wrapper is safe.
    static let installedHelperAppName = "RelayInputMethod" + variantSuffix + ".app"

    /// App → helper commands. Raw values are the CFMessagePort `msgid`.
    enum Command: Int32 {
        /// Liveness probe. Reply: `"ok"`.
        case ping = 1
        /// Begin a dictation in the **always-on** model (the helper is already the
        /// active source and bound to the focused field via the user's own focus
        /// changes). Sets the helper active. Reply: the bound client's bundle id, or
        /// empty when nothing insertable is bound (→ caller falls back).
        case beginDictation = 2
        /// Begin a dictation in the **just-in-time** model: the app has just
        /// `TISSelectInputSource(ours)`, so the helper performs the AppKit
        /// focus-churn back to the target pid (payload = pid in decimal) to force
        /// the TSM rebind, then sets active. Reply: bound client bundle id or empty.
        case engageJustInTime = 3
        /// Replace the live underlined composition with `payload` (the in-flight
        /// hypothesis). No reply.
        case setMarked = 4
        /// Commit `payload` as final text, ending the composition (replaces any
        /// marked text). No reply.
        case commit = 5
        /// Clear the live composition without committing. No reply.
        case clear = 6
        /// End the dictation: clear any composition and mark the helper inactive.
        /// No reply.
        case endDictation = 7
    }

    /// Helper → app events. Raw values are the CFMessagePort `msgid`. Best-effort /
    /// non-load-bearing: they drive UI display only (the command replies carry the
    /// authoritative engagement state).
    enum Event: Int32 {
        /// A focused client bound to the IME. Payload: client bundle id.
        case engaged = 1
        /// The bound client went away (focus left, or IME deselected). No payload.
        case disengaged = 2
    }

    // MARK: - Payload coding (UTF-8; nil-safe)

    static func data(_ string: String) -> Data { Data(string.utf8) }

    static func string(_ data: Data?) -> String {
        guard let data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
