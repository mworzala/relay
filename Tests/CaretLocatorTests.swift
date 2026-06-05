import XCTest
@testable import Relay

/// The pure AX→AppKit coordinate flip (`CaretLocator.flip`). AX rects are top-left
/// origin; AppKit is bottom-left. No live AX. `nonisolated` per the MainActor rule.
nonisolated final class CaretLocatorTests: XCTestCase {

    func testFlipSingleDisplay() {
        // A caret 100pt down from the top of a 900-tall primary screen, 20pt tall:
        // its AppKit bottom edge is 900 - 100 - 20 = 780.
        let ax = CGRect(x: 50, y: 100, width: 1, height: 20)
        let appKit = CaretLocator.flip(axRect: ax, primaryScreenHeight: 900)
        XCTAssertEqual(appKit, NSRect(x: 50, y: 780, width: 1, height: 20))
    }

    func testFlipTopOfScreen() {
        // Caret flush to the AX top (y=0) on an 800-tall screen → AppKit y = 800 - h.
        let ax = CGRect(x: 0, y: 0, width: 2, height: 16)
        let appKit = CaretLocator.flip(axRect: ax, primaryScreenHeight: 800)
        XCTAssertEqual(appKit, NSRect(x: 0, y: 784, width: 2, height: 16))
    }

    func testFlipPreservesWidthHeightAndX() {
        let ax = CGRect(x: 123.5, y: 250, width: 4, height: 18)
        let appKit = CaretLocator.flip(axRect: ax, primaryScreenHeight: 1080)
        XCTAssertEqual(appKit.origin.x, 123.5, accuracy: 0.001)
        XCTAssertEqual(appKit.width, 4, accuracy: 0.001)
        XCTAssertEqual(appKit.height, 18, accuracy: 0.001)
        XCTAssertEqual(appKit.origin.y, 1080 - 250 - 18, accuracy: 0.001)
    }

    func testFlipSecondaryDisplayAbovePrimary() {
        // A display stacked above the primary has negative AX-flipped y in AppKit
        // space (origin above the primary's top). A caret at AX y = -200 (200pt
        // above the primary's top) on a 1000-tall primary → AppKit y = 1000 + 200 - h.
        let ax = CGRect(x: 10, y: -200, width: 1, height: 14)
        let appKit = CaretLocator.flip(axRect: ax, primaryScreenHeight: 1000)
        XCTAssertEqual(appKit.origin.y, 1000 + 200 - 14, accuracy: 0.001)
    }
}
