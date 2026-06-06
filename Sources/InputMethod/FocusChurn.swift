import AppKit

/// The "macism focus-churn" — the verified mechanism that makes a just-in-time
/// `TISSelectInputSource(ours)` actually engage. `TISSelectInputSource` only
/// updates the *global* current-source record; the focused foreign app's TSM input
/// context re-binds to the new IME only on a real **frontmost-process transition**.
/// So we momentarily make this (`.accessory`) helper frontmost via
/// `NSApp.activate` with an off-screen, alpha-0 window, settle, then hand focus
/// back to the target app — that transition forces the rebind → `activateServer:`
/// fires on our controller.
///
/// Runs in the helper (an LSUIElement/`.accessory` process, exactly as the spike
/// verified) — no Accessibility permission. The window is invisible; the only
/// residual UX cost is a brief menu-bar flip on switch-in (unavoidable — §2). The
/// switch-*back* is free and needs no churn, so the app restores the previous
/// source directly with no second flip.
///
/// `nonisolated`: invoked from the CFMessagePort callout, which is serviced on the
/// helper's main run loop (AppKit work must be on main — it is).
nonisolated enum FocusChurn {
    /// Perform the churn, handing focus back to `targetPID`. `settleMs` is how long
    /// to hold focus before handing back (~150 ms verified). Blocks (pumping the run
    /// loop) until the hand-back has had time to fire `activateServer:`.
    static func perform(targetPID: pid_t, settleMs: Int = 150) {
        // The CFMessagePort source is scheduled on the main run loop, so this fires
        // on the main thread — assert that (a clearer debug failure than the bare
        // MainActor.assumeIsolated trap) before treating it as MainActor-isolated.
        assert(Thread.isMainThread, "FocusChurn.perform must run on the main thread")
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)   // no Dock icon (idempotent for LSUIElement)

            // Off-screen + fully transparent: never visible.
            let panel = NSPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.alphaValue = 0
            panel.hasShadow = false
            panel.level = .floating
            panel.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)   // becomes frontmost (flips the menu bar)
            spin(ms: max(settleMs, 120))

            panel.orderOut(nil)
            // Hand focus back to the target → its TSM context rebinds to our IME.
            if targetPID > 0 {
                NSRunningApplication(processIdentifier: targetPID)?.activate()
            }
            spin(ms: 500)   // let activateServer: fire on our controller before we reply
        }
        IMKLog.write("focus-churn done → target pid=\(targetPID)")
    }

    /// Pump the run loop for `ms` so AppKit/IMK machinery is serviced while we wait
    /// (a bare sleep would starve the activation we just triggered).
    private static func spin(ms: Int) {
        guard ms > 0 else { return }
        let deadline = Date().addingTimeInterval(Double(ms) / 1000.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }
}
