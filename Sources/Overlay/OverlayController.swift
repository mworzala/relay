import AppKit
import Observation
import SwiftUI

/// Owns the floating dictation pill: a borderless, non-activating `NSPanel`
/// hosting the Liquid Glass SwiftUI view. Shown only while dictating, positioned
/// bottom-center of the screen under the cursor, above everything (incl.
/// full-screen apps). Drives the waveform + elapsed timer from a 30 Hz timer.
@MainActor
@Observable
final class OverlayController {
    static let barCount = 23

    private(set) var levels: [Float] = Array(repeating: 0, count: barCount)
    private(set) var elapsed: TimeInterval = 0

    /// Supplies the current input level (0…1) — wired to the microphone meter.
    @ObservationIgnored var levelSource: (() -> Float)?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startDate: Date?

    private static let panelSize = NSSize(width: 230, height: 60)

    func show() {
        levels = Array(repeating: 0, count: Self.barCount)
        elapsed = 0
        startDate = Date()
        ensurePanel()
        positionPanel()
        fadeIn()
        startTimer()
    }

    func hide() {
        stopTimer()
        fadeOut()
    }

    // MARK: - Panel

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Above everything, including full-screen apps.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0

        let host = NSHostingView(rootView: PillView(controller: self))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = Self.activeScreen()
        let visible = screen.frame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 92   // a little above the bottom edge
        )
        panel.setFrameOrigin(origin)
        NSLog("Relay overlay: frame=\(NSStringFromRect(panel.frame)) level=\(panel.level.rawValue) screen=\(NSStringFromRect(visible))")
    }

    /// The screen currently under the mouse (best proxy for "where the user is").
    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func fadeIn() {
        guard let panel else { return }
        panel.orderFrontRegardless()   // show without becoming key/active
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            // Completion fires on the main thread; assert it for the isolation checker.
            MainActor.assumeIsolated { panel?.orderOut(nil) }
        })
    }

    // MARK: - Animation timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let level = levelSource?() ?? 0
        var next = levels
        next.removeFirst()
        next.append(level)
        levels = next
        if let startDate { elapsed = Date().timeIntervalSince(startDate) }
    }
}
