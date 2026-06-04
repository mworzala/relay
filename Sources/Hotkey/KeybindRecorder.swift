import AppKit
import Observation

/// Click-to-record control backing for the keybind UI. While recording it
/// installs a LOCAL `NSEvent` monitor (the config window is frontmost) that
/// consumes events so the captured key doesn't also act. Captures either a combo
/// (key + modifiers, on key-down) or a bare modifier (on its release with no
/// intervening key-down), matching how the hold-to-talk default works.
@MainActor
@Observable
final class KeybindRecorder {
    private(set) var isRecording = false

    @ObservationIgnored var onCapture: ((Keybind) -> Void)?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var candidateModifier: UInt16?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        candidateModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil   // consume while recording
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        candidateModifier = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { stop(); return }   // Esc cancels
            let modifiers = event.modifierFlags.intersection(.relevant)
            capture(Keybind(keyCode: event.keyCode, modifiers: modifiers.rawValue, isBareModifier: false))

        case .flagsChanged:
            guard let flag = Self.modifierFlag(for: event.keyCode) else { return }
            if event.modifierFlags.contains(flag) {
                candidateModifier = event.keyCode               // pressed
            } else if candidateModifier == event.keyCode {
                capture(Keybind(keyCode: event.keyCode, modifiers: 0, isBareModifier: true))  // released → bare
            }

        default:
            break
        }
    }

    private func capture(_ keybind: Keybind) {
        onCapture?(keybind)
        stop()
    }

    /// Device-independent modifier flag a modifier key contributes (used to tell
    /// press from release on `.flagsChanged`).
    static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }
}
