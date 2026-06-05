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
        let pb = NSPasteboard(name: NSPasteboard.Name("com.relay.tests.\(name)"))
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

    func testRestoreEmptySnapshotClearsBoard() {
        let pb = makePasteboard("empty")
        let snap = Clipboard.save(from: pb)   // captured while empty

        _ = Clipboard.setStringForPaste("temp", to: pb)
        Clipboard.restore(snap, to: pb)

        XCTAssertNil(pb.string(forType: .string))

        pb.clearContents()
    }
}
