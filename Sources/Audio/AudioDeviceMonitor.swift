import CoreAudio
import Foundation
import Observation

/// Watches the Core Audio HAL for input-device add/remove and exposes the current
/// set of connected input devices. Drives priority routing: highest-priority
/// connected device wins, with automatic fall-down / switch-back.
@MainActor
@Observable
final class AudioDeviceMonitor {
    private(set) var connectedDevices: [AudioInputDevice]

    /// Called on the main actor whenever the connected set actually changes.
    @ObservationIgnored var onDevicesChanged: (() -> Void)?

    @ObservationIgnored private var listenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private let listenerQueue =
        DispatchQueue(label: "com.relay.audio.device-listener")

    init() {
        connectedDevices = CoreAudioDevices.inputDevices()
    }

    func start() {
        guard listenerBlock == nil else { return }
        var address = CoreAudioDevices.address(kAudioHardwarePropertyDevices)
        // `@Sendable` so this isn't inferred @MainActor under MainActor-default
        // isolation — Core Audio calls it on `listenerQueue`, not the main thread,
        // which would otherwise trap (swift_task_checkIsolated).
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        if status == noErr {
            listenerBlock = block
        } else {
            NSLog("Relay: failed to add device listener (status \(status))")
        }
    }

    func stop() {
        guard let block = listenerBlock else { return }
        var address = CoreAudioDevices.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        listenerBlock = nil
    }

    func refresh() {
        let updated = CoreAudioDevices.inputDevices()
        guard updated != connectedDevices else { return }
        connectedDevices = updated
        onDevicesChanged?()
    }

    /// The device to actually record from given the persisted priority order.
    /// Highest-priority *connected* device wins; otherwise the system default
    /// input; otherwise any connected device.
    func activeDevice(for priority: [MicPriorityEntry]) -> AudioInputDevice? {
        for entry in priority {
            if let device = connectedDevices.first(where: { $0.uid == entry.uid }) {
                return device
            }
        }
        if let defaultUID = CoreAudioDevices.defaultInputUID(),
           let device = connectedDevices.first(where: { $0.uid == defaultUID }) {
            return device
        }
        return connectedDevices.first
    }
}
