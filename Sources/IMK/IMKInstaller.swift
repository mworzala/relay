import AppKit
import Carbon

/// Installs / inspects / removes Relay's bundled IME via the Text Input Sources
/// (TIS) API. All TIS calls run on the main actor (TIS is documented main-thread-
/// only for UI apps); this type is MainActor-isolated by the project default.
///
/// The verified call sequence (from the IMK spike): copy the embedded
/// `RelayInputMethod.app` into `~/Library/Input Methods/`, `TISRegisterInputSource`,
/// then `TISEnableInputSource` the **select-capable** mode (an IMKit method
/// registers two entries — a non-selectable container and the selectable input
/// mode; enabling/selecting the container returns paramErr (-50)).
enum IMKInstaller {

    /// The embedded helper inside Relay.app (the install payload). Stable name in
    /// every variant so the Xcode embed phase is happy; the variants are separated at
    /// install time by the destination name (see `installURL`).
    static var embeddedAppURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/InputMethods/RelayInputMethod.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where an installed IME must live. The wrapper name is variant-suffixed
    /// (RelayInputMethod.app vs RelayInputMethod.dev.app) so the dev and installed
    /// copies don't overwrite each other in ~/Library/Input Methods/.
    static var installURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/\(IMKMessaging.installedHelperAppName)")
    }

    /// Outcome of the copy+register step. Whether the source is actually *usable*
    /// (enabled) is a separate question the caller answers via `isEnabled()` polling
    /// — a freshly-registered third-party IME can't be enabled until a logout/login
    /// or a manual add in System Settings (gotcha §3.4), regardless of which process
    /// calls `TISEnableInputSource` (it returns noErr but no-ops until then).
    enum InstallResult: Equatable {
        case ok
        case failed(String)
    }

    // MARK: - State queries

    /// Whether the *current* helper is installed — identity-aware, not just a path
    /// check. A bundle from a previous build can sit at `installURL` with a different
    /// `CFBundleIdentifier` (e.g. after the org-id rename: an old
    /// `com.relay.inputmethod.RelayInputMethod` lingering where the new
    /// `com.mattworzala…` one belongs). The wrapper filename doesn't carry the org
    /// id, so a path-only check reads stale as installed and soft-locks setup in
    /// `.needsActivation` (no reinstall affordance). Treating an id-mismatched bundle
    /// as not-installed reopens the **Set up** path, which overwrites it with the
    /// embedded current build.
    static func isInstalled() -> Bool {
        installedBundleID() == IMKMessaging.helperBundleID
    }

    /// The `CFBundleIdentifier` of whatever helper is currently at `installURL`, or
    /// nil if nothing is installed there / it isn't a readable bundle. Reads the
    /// `Info.plist` straight off disk rather than via `Bundle(url:)` — `Bundle`
    /// caches per URL process-wide, so right after `install()` overwrites the bundle
    /// in place it would hand back the *previous* build's id.
    static func installedBundleID() -> String? {
        let plistURL = installURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization
                  .propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Our selectable input *mode* (the entry that can actually be enabled/selected).
    static func selectableSource() -> TISInputSource? {
        ourSources().first { boolProp($0, kTISPropertyInputSourceIsSelectCapable) }
    }

    static func isEnabled() -> Bool {
        guard let src = selectableSource() else { return false }
        return boolProp(src, kTISPropertyInputSourceIsEnabled)
    }

    // MARK: - Install / uninstall

    /// Copy the embedded helper into `~/Library/Input Methods/` and register it.
    /// Enabling is left to the helper (it activates itself from its own process) and
    /// to the user's logout/login or System Settings add — `IMKController` polls
    /// `isEnabled()` for the actual outcome.
    @discardableResult
    static func install() -> InstallResult {
        guard let embedded = embeddedAppURL else {
            return .failed("RelayInputMethod.app is not embedded in this build")
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: installURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: installURL.path) {
                try fm.removeItem(at: installURL)
            }
            try fm.copyItem(at: embedded, to: installURL)
        } catch {
            return .failed("copy failed: \(error.localizedDescription)")
        }

        // Register so the source is queryable immediately (the helper also registers
        // itself; this is idempotent). Mid-session this surfaces a fresh bundle id.
        let regStatus = TISRegisterInputSource(installURL as CFURL)
        NSLog("Relay/imk: TISRegisterInputSource → \(regStatus)")
        return .ok
    }

    /// Re-copy the embedded helper over the installed one when they differ, so a
    /// rebuilt app doesn't keep running a *stale* installed helper. This matters most
    /// in dev, where the helper changes on every build but `isInstalled()` (a bundle-
    /// id match) stays true, so nothing would otherwise refresh the copy in
    /// `~/Library/Input Methods/`. Compares the helper executable's modification date
    /// (a fresh build's embedded payload is strictly newer); terminates a running
    /// helper first so the file can be replaced, and the caller's `start()` relaunches
    /// it. No-op when not installed, already current, or there's no embedded payload.
    @discardableResult
    static func refreshInstalledHelperIfStale() -> Bool {
        guard isInstalled(), let embedded = embeddedAppURL else { return false }
        guard let embeddedDate = helperExecutableModDate(embedded),
              let installedDate = helperExecutableModDate(installURL),
              embeddedDate > installedDate else { return false }

        IMKProcessManager.terminate()
        let fm = FileManager.default
        do {
            try fm.removeItem(at: installURL)
            try fm.copyItem(at: embedded, to: installURL)
        } catch {
            NSLog("Relay/imk: helper refresh failed: \(error.localizedDescription)")
            return false
        }
        let regStatus = TISRegisterInputSource(installURL as CFURL)
        NSLog("Relay/imk: refreshed stale installed helper, TISRegisterInputSource → \(regStatus)")
        return true
    }

    /// Modification date of the helper's Mach-O executable inside an `.app`. The
    /// executable name is the (variant-stable) `PRODUCT_NAME`, "RelayInputMethod".
    private static func helperExecutableModDate(_ appURL: URL) -> Date? {
        let exe = appURL.appendingPathComponent("Contents/MacOS/RelayInputMethod")
        let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Deep link to System Settings ▸ Keyboard, where the user can add Relay under
    /// Input Sources (the reliable manual activation path).
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Disable our source(s) and remove the bundle. The caller should first restore
    /// the user's previous input source if ours is currently selected (IMKSwitcher).
    static func uninstall() {
        for src in ourSources() {
            let status = TISDisableInputSource(src)
            NSLog("Relay/imk: disable \(stringProp(src, kTISPropertyInputSourceID)) → \(status)")
        }
        try? FileManager.default.removeItem(at: installURL)
    }

    // MARK: - TIS helpers (mirrors the verified spike)

    static func ourSources() -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: IMKMessaging.helperBundleID] as CFDictionary
        guard let cf = TISCreateInputSourceList(filter, true)?.takeRetainedValue() else { return [] }
        return (cf as NSArray) as? [TISInputSource] ?? []
    }

    static func stringProp(_ src: TISInputSource?, _ key: CFString) -> String {
        guard let src, let ptr = TISGetInputSourceProperty(src, key) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }
}
