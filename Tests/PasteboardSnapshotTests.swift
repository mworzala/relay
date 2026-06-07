import AppKit
import XCTest
@testable import Relay

/// Clipboard save/restore round-trip for "Overlay + paste" finalize. Runs against a
/// **private**, uniquely-named pasteboard so it never clobbers the developer's real
/// clipboard. `nonisolated` per the MainActor-default rule; the `Clipboard` helpers
/// under test are themselves `nonisolated`.
nonisolated final class PasteboardSnapshotTests: XCTestCase {

    /// A fresh private pasteboard per test, emptied on teardown.
    private func makePasteboard(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.mattworzala.tests.\(name)"))
        pb.clearContents()
        return pb
    }

    func testStringRoundTrip() {
        let pb = makePasteboard("string")
        pb.setString("user's original", forType: .string)

        let snap = Clipboard.save(from: pb)

        // Simulate the transient dictation copy.
        _ = Clipboard.setStringForPaste("DICTATED TEXT", to: pb)
        XCTAssertEqual(pb.string(forType: .string), "DICTATED TEXT")

        Clipboard.restore(snap, to: pb)
        XCTAssertEqual(pb.string(forType: .string), "user's original")

        pb.clearContents()
    }

    func testMultipleTypesRoundTrip() {
        let pb = makePasteboard("multitype")
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        let rtf = Data("rtf-bytes".utf8)
        item.setData(rtf, forType: .rtf)
        pb.writeObjects([item])

        let snap = Clipboard.save(from: pb)
        _ = Clipboard.setStringForPaste("temp", to: pb)
        Clipboard.restore(snap, to: pb)

        XCTAssertEqual(pb.string(forType: .string), "plain")
        XCTAssertEqual(pb.data(forType: .rtf), rtf)

        pb.clearContents()
    }

    func testChangeCountCapturedAndBumpsOnWrite() {
        let pb = makePasteboard("changecount")
        pb.setString("seed", forType: .string)

        let snap = Clipboard.save(from: pb)
        let afterWrite = Clipboard.setStringForPaste("new", to: pb)

        // Writing bumps the change count past the captured value — this is exactly
        // the signal PasteInjector uses to detect a competing copy before restoring.
        XCTAssertGreaterThan(afterWrite, snap.changeCount)

        pb.clearContents()
    }

    func testShouldRestoreOnlyWhenNothingWroteSince() {
        // The exact decision PasteInjector makes before restoring (extracted so it's
        // testable without driving NSPasteboard.general / CGEvent / a real sleep).
        XCTAssertTrue(PasteInjector.shouldRestore(afterWrite: 7, current: 7))
        XCTAssertFalse(PasteInjector.shouldRestore(afterWrite: 7, current: 8))
    }

    func testRestoreDecisionAgainstACompetingCopy() {
        // Integration of the rule against a real (private) board: our write sets the
        // baseline; a competing copy afterwards bumps the count, so the guard declines
        // to restore and the user's newer clipboard survives.
        let pb = makePasteboard("competing")
        pb.setString("original", forType: .string)
        let snap = Clipboard.save(from: pb)
        let afterWrite = Clipboard.setStringForPaste("dictated", to: pb)

        // No competing write → restore happens, prior clipboard comes back.
        if PasteInjector.shouldRestore(afterWrite: afterWrite, current: pb.changeCount) {
            Clipboard.restore(snap, to: pb)
        }
        XCTAssertEqual(pb.string(forType: .string), "original")

        // Now a competing copy after our write → restore is skipped.
        let afterWrite2 = Clipboard.setStringForPaste("dictated again", to: pb)
        _ = Clipboard.setStringForPaste("user copied this", to: pb)
        XCTAssertFalse(PasteInjector.shouldRestore(afterWrite: afterWrite2, current: pb.changeCount))

        pb.clearContents()
    }

    func testRestoreEmptySnapshotClearsBoard() {
        let pb = makePasteboard("empty")
        let snap = Clipboard.save(from: pb)   // captured while empty

        _ = Clipboard.setStringForPaste("temp", to: pb)
        Clipboard.restore(snap, to: pb)

        XCTAssertNil(pb.string(forType: .string))

        pb.clearContents()
    }
}
