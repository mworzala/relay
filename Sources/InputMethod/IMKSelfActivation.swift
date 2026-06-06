import Carbon
import Foundation

/// Registers and enables our own input source — performed by the helper **from its
/// own process**, because macOS only honors `TISEnableInputSource` for a
/// third-party input method when the call comes from that method's own bundle
/// (calling it from the main Relay app returns noErr but silently no-ops). The main
/// app copies the bundle and launches us; we activate ourselves and the one-time
/// consent prompt appears here. Idempotent — re-enabling an already-enabled source
/// is a harmless no-op (no repeat prompt).
nonisolated enum IMKSelfActivation {
    static func registerAndEnable() {
        let reg = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        IMKLog.write("self: TISRegisterInputSource(\(Bundle.main.bundleURL.lastPathComponent)) → \(reg)")

        let filter = [kTISPropertyBundleID as String: IMKMessaging.helperBundleID] as CFDictionary
        guard let cf = TISCreateInputSourceList(filter, true)?.takeRetainedValue() else {
            IMKLog.write("self: no TIS sources for our bundle yet")
            return
        }
        let sources = (cf as NSArray).compactMap { $0 as! TISInputSource? }
        for src in sources {
            let selectable = (TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable)
                .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) }) ?? false
            let status = TISEnableInputSource(src)
            let enabled = (TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled)
                .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) }) ?? false
            IMKLog.write("self: enable selectable=\(selectable) status=\(status) → enabled=\(enabled)")
        }
    }
}
