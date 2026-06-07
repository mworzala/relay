import AppKit
import Observation
import SwiftUI

/// Owns the caret-anchored live-transcript box used by "Overlay + paste" mode — a
/// borderless, non-activating, click-through `NSPanel` (same pattern as the
/// dictation pill) hosting `TranscriptOverlayView`. Shown on session start in that
/// mode, fed the streaming hypothesis, and faded out after the paste finalizes.
///
/// A separate controller from `OverlayController` so the pill code stays untouched;
/// the pill (waveform + timer) still shows alongside this in overlay-paste mode.
@MainActor
@Observable
final class TranscriptOverlayController {
    /// The current committed/volatile split, observed by `TranscriptOverlayView`.
    private(set) var segments = TranscriptSegments(confirmed: "", volatile: "")

    @ObservationIgnored private var panel: NSPanel?
    /// The resolved caret anchor in AppKit space (nil → bottom-center fallback).
    @ObservationIgnored private var anchor: NSRect?
    /// Serial off-main queue for the (potentially blocking) AX caret query.
    @ObservationIgnored private let locateQueue = DispatchQueue(label: "com.mattworzala.caret-locator")
    /// Generation token so a stale async caret result from a previous session can't
    /// reposition a newer one.
    @ObservationIgnored private var generation = 0

    /// The visible card's maximum width: `TranscriptOverlayView`'s text cap (440) +
    /// its horizontal padding (16 × 2). The on-screen clamp uses this — not the
    /// panel width — so the card never gets nudged left of the caret by surplus
    /// transparent panel area near the right screen edge.
    static let cardMaxWidth: CGFloat = 440 + 32
    /// Wide and tall enough to fully contain a max-width 3-line card; the panel is
    /// transparent and click-through, so only the card inside is visible and its
    /// surplus area is harmless (it may sit partly off the top of the screen near a
    /// high caret).
    private static let panelSize = NSSize(width: cardMaxWidth + 16, height: 160)
    /// Gap between the caret and the bottom of the card.
    private static let caretGap: CGFloat = 8
    /// Inset the card's left edge slightly left of the caret.
    private static let caretInsetX: CGFloat = 6

    /// Start a fresh overlay session: reset the text, resolve the caret anchor
    /// off-main, and reveal the (initially empty) panel.
    func begin() {
        segments = TranscriptSegments(confirmed: "", volatile: "")
        generation += 1
        ensurePanel()
        resolveAnchor()
        fadeIn()
    }

    /// Push a new streaming hypothesis into the card.
    func update(confirmed: String, volatile: String) {
        segments = TranscriptSegments(confirmed: confirmed, volatile: volatile)
        // The card grows with the text; keep it seated against the caret.
        positionPanel()
    }

    /// Fade the overlay out (the paste happens independently in `PasteInjector`).
    func end() {
        generation += 1
        fadeOut()
    }

    // MARK: - Anchor resolution

    private func resolveAnchor() {
        let token = generation
        let primaryHeight = Self.primaryScreenHeight()
        locateQueue.async {
            let rect = CaretLocator.locate(primaryScreenHeight: primaryHeight)
            Task { @MainActor in
                guard token == self.generation else { return }   // a newer session won
                self.anchor = rect
                self.positionPanel()
            }
        }
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
        panel.ignoresMouseEvents = true   // click-through: never steals the caret
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0

        let host = NSHostingView(rootView: TranscriptOverlayView(controller: self))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
    }

    /// Seat the panel so the card's bottom-left corner sits just above the caret.
    /// The card is bottom-leading inside the panel, so it grows upward as it gains
    /// lines; the surplus panel area above can run off-screen harmlessly. Falls back
    /// to bottom-center (near the pill) when there's no anchor.
    private func positionPanel() {
        guard let panel else { return }
        let size = panel.frame.size

        guard let caret = anchor else {
            guard let visible = Self.activeScreen()?.frame else { return }
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.minY + 160))
            return
        }

        guard let visible = (Self.screen(containing: caret) ?? Self.activeScreen())?.visibleFrame
        else { return }
        // Keep a full-width *card* (not the wider transparent panel) on screen
        // horizontally so a wide card is never clipped and a short one still sits
        // flush under the caret; vertically, place the bottom just above the caret
        // and let the empty top run off-screen if need be.
        var x = caret.minX - Self.caretInsetX
        x = min(max(visible.minX, x), visible.maxX - Self.cardMaxWidth)
        let y = caret.maxY + Self.caretGap
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func fadeIn() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                // Skip if a newer begin() re-displayed the panel during the fade
                // (the generation token is already bumped by begin()/end()).
                guard let self, self.generation == gen else { return }
                panel?.orderOut(nil)
            }
        })
    }

    // MARK: - Screens

    /// Height of the primary display (origin == .zero) — the reference for the
    /// AX→AppKit vertical flip. Resolved on the main actor and handed to the
    /// off-main locator.
    private static func primaryScreenHeight() -> CGFloat {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        return primary?.frame.height ?? 0
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    /// nil when no displays are attached (don't force `screens[0]`, which traps on
    /// an empty array); callers skip positioning in that case.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
