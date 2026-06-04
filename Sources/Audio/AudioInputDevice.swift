import CoreAudio

/// A connected audio input device. Persist the `uid` (stable across reconnects /
/// reboots); the `id` (AudioDeviceID) is transient and must be re-resolved each
/// time the device set changes.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}
