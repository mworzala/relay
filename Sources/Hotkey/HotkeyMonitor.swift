import AppKit

/// Global + local **passive** hold-to-talk detection via `NSEvent` monitors for
/// `.flagsChanged`/`.keyDown`/`.keyUp`:
///   - the GLOBAL monitor observes events from other apps (gated by Accessibility,
///     requested in the wizard) and by design can never consume them;
///   - the LOCAL monitor covers the case where Relay itself is frontmost and
///     returns the event unchanged, so the keyboard behaves completely normally.
///
/// Both fire on the main thread; decoding is delegated to the pure `HotkeyMatcher`.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var matcher: HotkeyMatcher
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

    init(keybind: Keybind) {
        matcher = HotkeyMatcher(keybind: keybind)
    }

    /// Update the bind (from the keybind UI) without tearing down monitors.
    func setKeybind(_ keybind: Keybind) {
        matcher.keybind = keybind
        matcher.reset()
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event   // passive: never consume
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Ignore Relay's own synthetic keystrokes (⌘V / caret repair) so it never
        // reacts to events it posted itself. The hold-to-talk matcher already filters
        // by key, so there's no misfire today; this is a defensive guard that keeps
        // future key-watching robust. Best-effort — some event paths drop the
        // user-data field (`cgEvent` may also be nil for non-CG events).
        if let cgEvent = event.cgEvent, SyntheticKeys.isRelaySynthetic(cgEvent) { return }

        let transition: HotkeyMatcher.Transition?
        switch event.type {
        case .flagsChanged:
            transition = matcher.handleFlagsChanged(keyCode: event.keyCode, flags: event.modifierFlags)
        case .keyDown:
            transition = event.isARepeat
                ? nil
                : matcher.handleKeyDown(keyCode: event.keyCode, flags: event.modifierFlags)
        case .keyUp:
            transition = matcher.handleKeyUp(keyCode: event.keyCode, flags: event.modifierFlags)
        default:
            transition = nil
        }

        switch transition {
        case .press: onPress?()
        case .release: onRelease?()
        case nil: break
        }
    }
}
