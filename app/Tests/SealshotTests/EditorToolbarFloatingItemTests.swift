import AppKit
import XCTest
@testable import Sealshot

@MainActor
final class EditorToolbarFloatingItemTests: XCTestCase {

    /// The switcher used to be centred by SYMMETRY — `[.flexibleSpace, tabs,
    /// .flexibleSpace]`. Appending a trailing item to that array would shove it
    /// left by half the new item's width, so centring had to move to
    /// `centeredItemIdentifier` before the button could be added.
    func testToolbar_neverCentresTheSwitcherBySymmetryAlone() {
        let ids = EditorWindowController.toolbarDefaultIDs
        XCTAssertEqual(ids.first, EditorWindowController.tabsItemIDForTesting)
        XCTAssertEqual(ids.filter { $0 == .flexibleSpace }.count, 1,
                       "a second flexible space means the switcher is being centred by symmetry")
    }

    func testToolbar_putsTheFloatingWindowItemAtTheTrailingEdge() {
        XCTAssertEqual(EditorWindowController.toolbarDefaultIDs.last,
                       EditorWindowController.floatingItemID)
    }

    func testToolbar_allowsBothItems() {
        let ids = EditorWindowController.toolbarAllowedIDs
        XCTAssertTrue(ids.contains(EditorWindowController.tabsItemIDForTesting))
        XCTAssertTrue(ids.contains(EditorWindowController.floatingItemID))
    }

    func testFloatingItem_usesPipEnterWhenClosedAndPipExitWhenOpen() {
        XCTAssertEqual(EditorWindowController.floatingWindowSymbol(isOpen: false), "pip.enter")
        XCTAssertEqual(EditorWindowController.floatingWindowSymbol(isOpen: true), "pip.exit")
    }

    /// Both symbols must actually resolve — a missing SF Symbol draws nothing
    /// and fails no build.
    func testFloatingItem_bothSymbolsResolveOnThisOS() {
        for name in ["pip.enter", "pip.exit"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                            "\(name) does not resolve")
        }
    }
}
