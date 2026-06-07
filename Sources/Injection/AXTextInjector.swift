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
    private let queue = DispatchQueue(label: "com.mattworzala.ax-injector")

    private enum WriteMode: String { case selectedText, value }

    // --- State, only touched on `queue` ---
    private var element: AXUIElement?
    private var writeMode: WriteMode = .selectedText
    private var insertionStart = 0       // UTF-16 offset where dictation begins
    private var initialSelection = 0     // selection length to replace on the 1st write
    private var insertedLength = 0       // UTF-16 length we last wrote (our region size)
    private var lastWritten = ""         // last target we wrote (no-op + first-write check)
    private var trailingLength = 0       // UTF-16 units after our region (mid-field splice)
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
            self.trailingLength = 0
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
        // Snapshot the value before the first selectedText write so we can tell if
        // the field actually applied it (native) or ignored it (Chromium/Electron).
        let valueBefore = (firstWrite && writeMode == .selectedText) ? AXText.value(of: element) : nil

        var ok = write(target, regionLength: regionLength, mode: writeMode, element: element)

        // First selectedText write that changed nothing → Chromium/Electron (inert
        // selected-text). Switch to the value path and TRUST it: Chromium *applies*
        // setValue, but its reads are unreliable (it can report a frozen length and
        // its placeholder as the value), so re-verifying would falsely conclude
        // "inert" and double-insert via the keystroke fallback.
        if ok, firstWrite, writeMode == .selectedText,
           !Self.changed(from: valueBefore, element: element),
           AXText.isSettable(element, kAXValueAttribute as String) {
            trace("selectedText inert — switching to value mode")
            writeMode = .value
            ok = write(target, regionLength: regionLength, mode: .value, element: element)
        }

        if ok {
            // Cursor ALWAYS visibly at the end of what we inserted.
            let end = insertionStart + target.utf16.count
            AXText.setSelectedRange(element, NSRange(location: end, length: 0))
            // Chromium's contenteditable rebuilds its DOM on setValue, collapsing
            // the caret to 0, and ignores AX selection writes (kAXSelectedTextRange).
            // It DOES honor real keystrokes, so on the final write repair the caret
            // with ⌘A→→ once the async DOM rebuild settles. (Native fields use
            // selectedText mode and are already positioned by the line above.)
            if final, writeMode == .value {
                // moveCaretToEnd (⌘A→→) lands at the absolute end of the field, which
                // is correct only when nothing follows our insertion. For a mid-field
                // splice (preserved trailing text) back the caret up by the trailing
                // length so it lands at the end of the dictation, not past the
                // following text.
                let trailing = trailingLength
                queue.asyncAfter(deadline: .now() + 0.15) {
                    SyntheticKeys.moveCaretToEnd()
                    SyntheticKeys.moveLeft(by: trailing)
                }
            }
            insertedLength = target.utf16.count
            lastWritten = target
            trace("\(writeMode.rawValue) wrote len=\(target.utf16.count) region=\(regionLength)\(final ? " (final)" : "")")
            report?("wrote \(target.utf16.count)")
        } else {
            // The AX call returned an error. On the first write nothing is on screen
            // yet → hand off to the keystroke fallback (works everywhere).
            active = false
            if firstWrite {
                // Restore the caret (a failed setValue can reset Chromium's selection
                // to 0) so the keystroke fallback appends instead of prepending.
                AXText.setSelectedRange(element, NSRange(location: insertionStart, length: 0))
                trace("AX write failed — falling back to keystrokes")
                report?("axFailed")
                fallback?()
            } else {
                trace("AX write failed — stopping AX")
                report?("axFailed")
            }
        }
    }

    /// Perform one write in the given mode. Returns whether the AX call reported
    /// success (not whether the read-back reflects it — Chromium reads lie).
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
            // At the very start of the field, replace the whole value with the
            // dictation. We deliberately do NOT read the existing value here:
            // Chromium reports its placeholder ("Write a message…") as the value
            // while empty, and splicing into that would inject the placeholder.
            // Mid-field (caret > 0, real content present) we splice to preserve the
            // surrounding text.
            let newValue: String
            if insertionStart == 0 {
                newValue = target
                trailingLength = 0   // whole value replaced — nothing after the caret
            } else if let value = AXText.value(of: element) {
                // UTF-16 units after our region = preserved trailing text the final
                // caret repair must back up over.
                trailingLength = max(0, value.utf16.count - (insertionStart + regionLength))
                newValue = AXText.splicedValue(
                    value, insertionStart: insertionStart, regionLength: regionLength, target: target)
            } else {
                return false
            }
            return AXText.setValue(element, newValue)
        }
    }

    /// Whether the field's content actually changed after a write (used only to
    /// detect inert selected-text on the first write). Compares the full value, not
    /// the length count (which Chromium freezes). A nil `before` → assume changed.
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
