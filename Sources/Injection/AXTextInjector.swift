import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Primary injection strategy: keeps the focused field's dictation region in sync
/// with the latest hypothesis via the Accessibility API. It tracks exactly what it
/// inserted (`insertedLength`) and replaces that region each render — robust to
/// apps whose reported length is unreliable (notably Chromium/Electron, which can
/// report a frozen `kAXNumberOfCharacters`).
///
/// Two write paths, chosen at session start by which attribute is settable:
/// - **selectedText** (native Cocoa): minimal range-replace of just the changed
///   span (`AXEdit`), against the field's actual current region content.
/// - **value** (Chromium/Electron): splice the target into the whole `kAXValue`.
///
/// Some Chromium elements report an attribute as settable but silently ignore the
/// write. So the **first** write is verified (did the field length actually grow?);
/// if not, the other write path is tried, and if that's also inert the session
/// hands off to the keystroke fallback. After every successful write the caret is
/// forced to the end of the inserted text.
///
/// `nonisolated` + `@unchecked Sendable`: lives off-main; all state on `queue`.
nonisolated final class AXTextInjector: TextInjecting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.relay.ax-injector")

    private enum WriteMode: String { case selectedText, value }

    // --- State, only touched on `queue` ---
    private var element: AXUIElement?
    private var writeMode: WriteMode = .selectedText
    private var insertionStart = 0       // UTF-16 offset where dictation begins
    private var initialSelection = 0     // selection length to replace on the 1st write
    private var insertedLength = 0       // UTF-16 length we last wrote (our region size)
    private var lastWritten = ""         // last target we wrote (no-op + first-write check)
    private var active = false
    private var report: (@Sendable (String) -> Void)?
    private var fallback: (@Sendable () -> Void)?

    private static let tracing = RelayDebug.injectTracing

    func beginSession(context: InjectionContext) {
        queue.async {
            self.report = context.report
            self.fallback = context.fallback
            self.lastWritten = ""
            self.insertedLength = 0
            guard let element = context.element else {
                self.element = nil
                self.active = false
                return
            }
            AXText.setTimeout(element)
            self.element = element
            self.writeMode = AXText.isSettable(element, kAXSelectedTextAttribute as String)
                ? .selectedText : .value
            let sel = AXText.selectedRange(of: element)
            self.insertionStart = sel?.location ?? context.caretLocation
            self.initialSelection = sel?.length ?? 0
            self.active = true
            self.trace("begin mode=\(self.writeMode.rawValue) start=\(self.insertionStart) initialSel=\(self.initialSelection)")
        }
    }

    func render(_ target: String) {
        queue.async { self.apply(target, final: false) }
    }

    func finalize(_ finalText: String) {
        queue.async {
            self.apply(finalText, final: true)
            self.element = nil
            self.active = false
            self.report = nil
            self.fallback = nil
        }
    }

    // MARK: - Implementation (on `queue`)

    private func apply(_ target: String, final: Bool) {
        guard active, let element else { return }
        guard target != lastWritten else { return }

        if IsSecureEventInputEnabled() {
            active = false
            trace("secure input mid-session — stopping AX")
            report?("secure")
            return
        }
        if focusChanged(from: element) {
            active = false
            trace("focus moved — stopping AX")
            report?("focusMoved")
            return
        }

        let firstWrite = lastWritten.isEmpty
        // Region to replace: the initial selection on the first write, our tracked
        // inserted text thereafter.
        let regionLength = firstWrite ? initialSelection : insertedLength
        // Snapshot the field's content before the FIRST write so we can verify it
        // actually changed — Chromium reports attributes settable yet ignores some
        // writes, and its length count is frozen, so we compare CONTENT not length.
        let before = firstWrite ? AXText.value(of: element) : nil

        var ok = write(target, regionLength: regionLength, mode: writeMode, element: element)

        // If the first write didn't change the field, try the other write path once.
        if ok, firstWrite, !Self.changed(from: before, element: element) {
            if writeMode == .selectedText, AXText.isSettable(element, kAXValueAttribute as String) {
                trace("selectedText write was inert — retrying via value")
                writeMode = .value
                ok = write(target, regionLength: regionLength, mode: .value, element: element)
                    && Self.changed(from: before, element: element)
            } else {
                ok = false
            }
        }

        if ok {
            // Cursor ALWAYS visibly at the end of what we inserted.
            let end = insertionStart + target.utf16.count
            AXText.setSelectedRange(element, NSRange(location: end, length: 0))
            insertedLength = target.utf16.count
            lastWritten = target
            trace("\(writeMode.rawValue) wrote len=\(target.utf16.count) region=\(regionLength)\(final ? " (final)" : "")")
            report?("wrote \(target.utf16.count)")
        } else {
            // Inert or failed. On the first write nothing is on screen yet, so hand
            // off to the keystroke fallback (which works everywhere, incl. Chromium).
            active = false
            if firstWrite {
                // A failed value-write can move the caret (Chromium resets the
                // selection on setValue). Restore it so the keystroke fallback
                // appends at the right place instead of prepending at 0.
                AXText.setSelectedRange(element, NSRange(location: insertionStart, length: 0))
                trace("AX write inert — falling back to keystrokes")
                report?("axInert")
                fallback?()
            } else {
                trace("AX write failed — stopping AX")
                report?("axFailed")
            }
        }
    }

    /// Perform one write in the given mode. Returns whether the AX call reported
    /// success (not whether it visibly took effect — see `tookEffect`).
    private func write(_ target: String, regionLength: Int, mode: WriteMode, element: AXUIElement) -> Bool {
        switch mode {
        case .selectedText:
            // Minimal edit against the field's actual current region content.
            let current = AXText.string(of: element, in: NSRange(location: insertionStart, length: regionLength))
                ?? lastWritten
            let edit = AXEdit.compute(previous: current, next: target, insertionStart: insertionStart)
            if edit.range.length == 0 && edit.replacement.isEmpty { return true }   // already matches
            return AXText.replace(element, range: edit.range, with: edit.replacement)
        case .value:
            guard let value = AXText.value(of: element) else { return false }
            let newValue = AXText.splicedValue(
                value, insertionStart: insertionStart, regionLength: regionLength, target: target)
            return AXText.setValue(element, newValue)
        }
    }

    /// Whether the field's content actually changed after a write. Compares the
    /// full value (not the length count, which Chromium freezes). A nil `before`
    /// snapshot (couldn't read) → assume success rather than falsely fall back.
    private static func changed(from before: String?, element: AXUIElement) -> Bool {
        guard let before else { return true }
        return AXText.value(of: element) != before
    }

    private func focusChanged(from sessionElement: AXUIElement) -> Bool {
        guard let current = AXFocus.focusedElement() else { return false }   // unknown → don't block
        return !CFEqual(current, sessionElement)
    }

    private func trace(_ message: @autoclosure () -> String) {
        if Self.tracing { NSLog("Relay/ax-inject: \(message())") }
    }
}
