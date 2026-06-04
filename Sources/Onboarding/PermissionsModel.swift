import AppKit
import ApplicationServices
import AVFoundation
import Observation

/// Tracks and requests the two permissions Relay needs (Microphone, Accessibility)
/// and polls for the Accessibility grant (which is granted out-of-process in
/// System Settings). Input Monitoring is intentionally NOT requested — the global
/// hold-to-talk observer uses an `NSEvent` `.flagsChanged` monitor, which is gated
/// by Accessibility alone.
@MainActor
@Observable
final class PermissionsModel {
    enum MicStatus { case notDetermined, granted, denied }

    private(set) var mic: MicStatus = .notDetermined
    private(set) var accessibilityTrusted = false

    @ObservationIgnored private var pollTimer: Timer?

    init() { refresh() }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .denied, .restricted: mic = .denied
        case .notDetermined: mic = .notDetermined
        @unknown default: mic = .notDetermined
        }
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        mic = granted ? .granted : .denied
    }

    /// Prompts for Accessibility AND registers Relay into the Accessibility list
    /// automatically (so the user never needs the `+` button), then starts polling
    /// for the grant.
    func requestAccessibility() {
        // Literal value of `kAXTrustedCheckOptionPrompt` — referencing the imported
        // global directly trips Swift 6's "shared mutable state" check, and the key
        // string is stable API.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        startPolling()
    }

    /// Deep-link straight to the Accessibility pane.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
