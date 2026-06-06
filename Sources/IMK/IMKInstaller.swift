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

    /// The embedded helper inside Relay.app (the install payload).
    static var embeddedAppURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/InputMethods/RelayInputMethod.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where an installed IME must live.
    static var installURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/RelayInputMethod.app")
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

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: installURL.path)
    }

    /// Our selectable input *mode* (the entry that can actually be enabled/selected).
    static func selectableSource() -> TISInputSource? {
        ourSources().first { boolProp($0, kTISPropertyInputSourceIsSelectCapable) }
    }

    static func isEnabled() -> Bool {
        guard let src = selectableSource() else { return false }
        return boolProp(src, kTISPropertyInputSourceIsEnabled)
    }

    static func isSelected() -> Bool {
        guard let src = selectableSource() else { return false }
        return boolProp(src, kTISPropertyInputSourceIsSelected)
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
