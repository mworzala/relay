import CoreAudio
import Foundation

/// Thin, thread-safe wrappers over the Core Audio HAL for enumerating input
/// devices and resolving stable UIDs. Pure functions (no shared state), so they
/// are `nonisolated` and safe to call from the device-change listener block.
enum CoreAudioDevices {

    nonisolated static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// All audio device IDs known to the system (input + output).
    nonisolated static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    /// True if the device exposes at least one input channel.
    nonisolated static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Read a CFString device property (UID, name, …).
    nonisolated static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, $0)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    nonisolated static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    nonisolated static func name(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    /// Every connected, user-selectable input device, with stable UID + name.
    /// Filters out the transient per-process aggregate devices that CoreAudio /
    /// AVAudioEngine auto-create (UID prefix `CADefaultDeviceAggregate`), which are
    /// internal plumbing and must not appear in the user's priority list.
    nonisolated static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInput(id), let uid = uid(of: id) else { return nil }
            guard !isInternalAggregate(uid: uid) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name(of: id) ?? uid)
        }
    }

    /// True for CoreAudio's auto-created per-process default-device aggregates.
    nonisolated static func isInternalAggregate(uid: String) -> Bool {
        uid.hasPrefix("CADefaultDeviceAggregate") || uid.hasPrefix("~:AMS2_Aggregate")
    }

    /// Resolve a (transient) AudioDeviceID for a persisted UID, if connected.
    nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    /// The system default input device's UID, used to seed priority on first run.
    nonisolated static func defaultInputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return uid(of: id)
    }
}
