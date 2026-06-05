import AppKit
import ApplicationServices
import Foundation

/// Locates the on-screen text caret (or a sensible fallback anchor) so the
/// transcript overlay can sit next to where the user is typing.
///
/// macOS has no "where is the caret" call; we read it through the Accessibility API
/// on the focused element: `kAXBoundsForRangeParameterizedAttribute` over a
/// zero-length selection range yields a thin I-beam rect at the caret. AX rects use
/// a **top-left** origin; AppKit windows use a **bottom-left** origin — `flip(...)`
/// converts, accounting for multiple displays by flipping against the primary
/// screen's height.
///
/// Falls back, in order, to the focused element's frame, then the mouse location,
/// then nil. `nonisolated`: the AX query runs on an off-main serial queue (it can
/// hang on an unresponsive app); the resolved AppKit-space rect is published to the
/// MainActor overlay controller. Reuses `AXFocus`/`AXText` so the focus ladder and
/// messaging timeout match the injection layer.
nonisolated enum CaretLocator {
    /// Resolve the best available caret anchor in AppKit screen coordinates, trying
    /// caret rect → focused-element frame → mouse. `primaryScreenHeight` is the
    /// primary display's height (resolved on the main actor and passed in, since
    /// `NSScreen` is main-actor state); it drives the AX→AppKit vertical flip.
    /// Returns nil only if there is no focused element *and* no mouse location.
    static func locate(primaryScreenHeight: CGFloat) -> NSRect? {
        guard let element = resolveFocusedElement() else { return mouseRect() }
        AXText.setTimeout(element)

        // Rung 1: exact caret rect.
        if let caret = caretRect(of: element, primaryScreenHeight: primaryScreenHeight) {
            return caret
        }
        // Rung 2: focused element frame.
        if let frame = elementFrame(of: element, primaryScreenHeight: primaryScreenHeight) {
            return frame
        }
        // Rung 3: mouse (the controller falls back to bottom-center when this is nil).
        return mouseRect()
    }

    // MARK: - Pure coordinate conversion (unit-tested)

    /// Convert an AX rect (top-left origin, in the global AX coordinate space) to an
    /// AppKit rect (bottom-left origin). AppKit's global space has its origin at the
    /// bottom-left of the **primary** display and AX's at the top-left of the same
    /// display, so a single primary height flips rects on any display:
    /// `appKitY = primaryHeight - axY - height`.
    static func flip(axRect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(
            x: axRect.origin.x,
            y: primaryScreenHeight - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }

    // MARK: - Element resolution

    /// The focused element, preferring the system-wide focus and falling back to the
    /// frontmost app's focused element (Chromium/Electron expose their web text
    /// control there, not system-wide). `AXText.focusedElement(ofApp:)` already
    /// guards a zero pid, so no extra check is needed.
    private static func resolveFocusedElement() -> AXUIElement? {
        if let e = AXFocus.focusedElement() { return e }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        return AXText.focusedElement(ofApp: pid)
    }

    // MARK: - Rungs

    /// Rung 1: the I-beam rect for a zero-length range at the caret (selection
    /// start), via `kAXBoundsForRangeParameterizedAttribute`. Returns AppKit space,
    /// or nil if the element doesn't expose usable geometry.
    private static func caretRect(of element: AXUIElement, primaryScreenHeight: CGFloat) -> NSRect? {
        guard let selection = AXText.selectedRange(of: element) else { return nil }
        var cfRange = CFRange(location: selection.location, length: 0)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &out) == .success,
            let value = out, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        // A caret rect is zero-WIDTH but must have a real height; guard against the
        // empty/at-origin rect some apps return when they don't actually support it.
        guard rect.height > 0 else { return nil }
        return flip(axRect: rect, primaryScreenHeight: primaryScreenHeight)
    }

    /// Rung 2: the focused element's frame, anchored at its lower-left. Tries the
    /// `AXFrame` convenience rect, else composes position + size.
    private static func elementFrame(of element: AXUIElement, primaryScreenHeight: CGFloat) -> NSRect? {
        if let rect = rectAttribute(element, "AXFrame"), rect.height > 0 {
            return flip(axRect: rect, primaryScreenHeight: primaryScreenHeight)
        }
        guard let pos = pointAttribute(element, kAXPositionAttribute as String),
              let size = sizeAttribute(element, kAXSizeAttribute as String),
              size.height > 0 else { return nil }
        return flip(axRect: CGRect(origin: pos, size: size), primaryScreenHeight: primaryScreenHeight)
    }

    /// Rung 3: a thin rect at the mouse location (already AppKit bottom-left space).
    /// `NSEvent.mouseLocation` is safe off-main (it queries the window server).
    private static func mouseRect() -> NSRect {
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x, y: p.y, width: 1, height: 16)
    }

    // MARK: - AXValue extraction

    private static func rectAttribute(_ element: AXUIElement, _ attribute: String) -> CGRect? {
        guard let value = axValue(element, attribute) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success,
              let value = out, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
