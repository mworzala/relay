import AppKit
import ApplicationServices
import Foundation

/// Reads the system-wide focused UI element via the Accessibility API.
/// `nonisolated` so the off-main injector queue can call it.
nonisolated enum AXFocus {
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &value)
        // Guard the type before the cast (matching the AXValue helpers): a forced
        // CFTypeRef cast would trap rather than degrade if the API ever returns
        // something else.
        guard result == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

/// Low-level Accessibility read/write primitives for *direct* text manipulation —
/// reading a field's value/selection and replacing a known range atomically.
///
/// **Units:** every offset/length is **UTF-16 (NSString) units**, which is what
/// the AX text APIs speak — *not* grapheme clusters. Keep all range math in UTF-16
/// and only convert at the boundaries; do not mix with `TextDiff`'s grapheme
/// counting.
///
/// `nonisolated`: invoked from the injector's serial `DispatchQueue`, off-main.
nonisolated enum AXText {
    /// Per-message AX timeout so a hung/unresponsive target app can't block the
    /// injector queue indefinitely.
    static let messagingTimeout: Float = 0.25

    // MARK: App identity

    struct AppIdentity {
        let pid: pid_t
        let bundleID: String?
        let name: String?
    }

    /// Resolve the owning app of an element: pid via AX, then bundle id + localized
    /// name via `NSRunningApplication`.
    static func appIdentity(of element: AXUIElement) -> AppIdentity {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let running = pid != 0 ? NSRunningApplication(processIdentifier: pid) : nil
        return AppIdentity(pid: pid,
                           bundleID: running?.bundleIdentifier,
                           name: running?.localizedName)
    }

    /// Best-effort: apply the standard messaging timeout to an element.
    static func setTimeout(_ element: AXUIElement, seconds: Float = messagingTimeout) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// The focused UI element as reported by the **application** element (not the
    /// system-wide focus). Chromium/Electron surface their focused web text control
    /// here once `AXManualAccessibility` is set, while the system-wide focus query
    /// stays nil for web content. Returns nil if the app reports no focused element.
    static func focusedElement(ofApp pid: pid_t) -> AXUIElement? {
        guard pid != 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: Reads

    /// The element's full text value (`kAXValue`), or nil if absent / non-string.
    static func value(of element: AXUIElement) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &out) == .success
        else { return nil }
        return out as? String
    }

    /// The number of characters (`kAXNumberOfCharacters`, UTF-16), or nil.
    static func characterCount(of element: AXUIElement) -> Int? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &out) == .success
        else { return nil }
        return (out as? NSNumber)?.intValue
    }

    /// The selected-text range (the caret/selection) as a UTF-16 `NSRange`, or nil.
    static func selectedRange(of element: AXUIElement) -> NSRange? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &out) == .success,
            let axValue = out, CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Substring for a UTF-16 range via the parameterized attribute, or nil if the
    /// range is out of bounds / unsupported.
    static func string(of element: AXUIElement, in range: NSRange) -> String? {
        guard range.length >= 0, range.location >= 0 else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString,
            axRange, &out) == .success
        else { return nil }
        return out as? String
    }

    // MARK: Capability probe

    /// Whether `attribute` is currently settable on the element.
    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    /// True if the element supports AX text replacement: a readable selection range
    /// **and** a settable `kAXSelectedText` *or* `kAXValue`. The injector picks the
    /// matching write path — native Cocoa fields take the `kAXSelectedText`
    /// range-replace; Chromium/Electron fields (which usually expose a settable
    /// `kAXValue` but **not** `kAXSelectedText`) take the whole-value set. Accepting
    /// either is what lets Electron apps use AX instead of the keystroke fallback.
    static func supportsTextEditing(_ element: AXUIElement) -> Bool {
        guard selectedRange(of: element) != nil else { return false }
        return isSettable(element, kAXSelectedTextAttribute as String)
            || isSettable(element, kAXValueAttribute as String)
    }

    // MARK: Writes

    /// Set the selection to a UTF-16 range. Returns success.
    @discardableResult
    static func setSelectedRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
    }

    /// Replace the current selection with `string`. Returns success.
    @discardableResult
    static func setSelectedText(_ element: AXUIElement, _ string: String) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, string as CFString) == .success
    }

    /// Set the element's whole text value (`kAXValue`). The Chromium/Electron write
    /// path — those fields take a settable value but not selected-text. Returns success.
    @discardableResult
    static func setValue(_ element: AXUIElement, _ string: String) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, string as CFString) == .success
    }

    /// Pure UTF-16 splice: replace `[insertionStart, insertionStart+regionLength)`
    /// of `value` with `target`. Used to build the whole-value set for the value
    /// write path. Offsets are clamped into bounds.
    static func splicedValue(_ value: String, insertionStart: Int, regionLength: Int, target: String) -> String {
        let units = Array(value.utf16)
        let start = min(max(0, insertionStart), units.count)
        let end = min(start + max(0, regionLength), units.count)
        let newUnits = Array(units[0..<start]) + Array(target.utf16) + Array(units[end...])
        return String(utf16CodeUnits: newUnits, count: newUnits.count)
    }

    /// Atomic range replacement: select `range`, then overwrite it with `string`.
    /// The target app performs the replacement as a single edit (autocorrect-safe).
    @discardableResult
    static func replace(_ element: AXUIElement, range: NSRange, with string: String) -> Bool {
        guard setSelectedRange(element, range) else { return false }
        return setSelectedText(element, string)
    }

    // MARK: Electron / Chromium manual accessibility

    /// Flip the private `AXManualAccessibility` / `AXEnhancedUserInterface` keys on
    /// the **application** element to coax Chromium/Electron into exposing an AX
    /// text tree. Best-effort: undocumented keys passed as plain strings — may be
    /// no-ops on some apps. Returns whether *either* set call reported success
    /// (not a guarantee the tree actually appeared — the caller must re-probe).
    @discardableResult
    static func enableManualAccessibility(pid: pid_t) -> Bool {
        guard pid != 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        let a = AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let b = AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return a == .success || b == .success
    }
}

/// A minimal UTF-16 replacement computed by diffing the previously-inserted text
/// against the new target, so an AX write touches only the changed middle (less
/// caret flicker / churn than re-writing the whole region every render).
///
/// Pure value type — no AX calls — so the range math unit-tests in isolation.
nonisolated struct AXEdit: Equatable {
    /// The field range (UTF-16) to overwrite, relative to the field's full value.
    let range: NSRange
    /// The replacement string for that range.
    let replacement: String
    /// The UTF-16 caret offset the field lands at after the edit (end of the
    /// inserted middle).
    let caretAfter: Int
    /// The new total inserted length (UTF-16) once applied (== `next.utf16.count`).
    let insertedLength: Int

    /// Diff `previous` (currently in the field, starting at `insertionStart`)
    /// against `next`, returning the smallest single-range replacement. Computes a
    /// common UTF-16 prefix **and** suffix and replaces only the divergent middle.
    /// For the common streaming case (append to the tail) the prefix is large and
    /// the suffix is empty, so this reduces to "replace the new tail".
    static func compute(previous: String, next: String, insertionStart: Int) -> AXEdit {
        let p = Array(previous.utf16)
        let n = Array(next.utf16)

        var pre = 0
        let preMax = min(p.count, n.count)
        while pre < preMax && p[pre] == n[pre] { pre += 1 }
        // Never split a surrogate pair: if the prefix boundary sits right after a
        // high surrogate, the diverging low half belongs to the changed region.
        // Otherwise an emoji→emoji swap that shares a high surrogate (e.g. 😀→😁,
        // both lead with U+D83D) would write a lone surrogate (→ U+FFFD) at a
        // mid-pair offset and corrupt the grapheme.
        if pre > 0, isHighSurrogate(p[pre - 1]) { pre -= 1 }

        var suf = 0
        let sufMax = min(p.count - pre, n.count - pre)
        while suf < sufMax && p[p.count - 1 - suf] == n[n.count - 1 - suf] { suf += 1 }
        // Same at the suffix boundary: if the common suffix begins on a low
        // surrogate, its high half is in the changed region — pull the low half in.
        if suf > 0, isLowSurrogate(n[n.count - suf]) { suf -= 1 }

        let oldChangedLength = p.count - pre - suf
        let newMiddle = Array(n[pre..<(n.count - suf)])
        let replacement = String(utf16CodeUnits: newMiddle, count: newMiddle.count)
        let range = NSRange(location: insertionStart + pre, length: oldChangedLength)
        let caretAfter = insertionStart + pre + newMiddle.count
        return AXEdit(range: range, replacement: replacement,
                      caretAfter: caretAfter, insertedLength: n.count)
    }

    private static func isHighSurrogate(_ u: UInt16) -> Bool { (0xD800...0xDBFF).contains(u) }
    private static func isLowSurrogate(_ u: UInt16) -> Bool { (0xDC00...0xDFFF).contains(u) }
}
