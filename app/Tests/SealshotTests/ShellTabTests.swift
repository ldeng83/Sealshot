import XCTest
@testable import Sealshot

final class ShellTabTests: XCTestCase {
    func testAllCasesOrder() {
        XCTAssertEqual(ShellTab.allCases, [.editor, .library, .settings])
    }
    func testTitles() {
        XCTAssertEqual(ShellTab.editor.title, "Editor")
        XCTAssertEqual(ShellTab.library.title, "Library")
        XCTAssertEqual(ShellTab.settings.title, "Settings")
    }
    func testShowsEditorToolbar_onlyForEditor() {
        XCTAssertTrue(ShellTab.editor.showsEditorToolbar)
        XCTAssertFalse(ShellTab.library.showsEditorToolbar)
        XCTAssertFalse(ShellTab.settings.showsEditorToolbar)
    }
    func testFromSegmentIndex() {
        XCTAssertEqual(ShellTab(segmentIndex: 0), .editor)
        XCTAssertEqual(ShellTab(segmentIndex: 1), .library)
        XCTAssertEqual(ShellTab(segmentIndex: 2), .settings)
        XCTAssertNil(ShellTab(segmentIndex: 3))
    }

    // MARK: - Dock reopen

    func testDockReopen_openWindowIsRaisedWithoutTouchingTheTab() {
        for tab in ShellTab.allCases {
            XCTAssertEqual(ShellTab.dockReopenAction(hasEditorWindow: true, lastSelectedTab: tab),
                           .raiseExisting,
                           "a Dock click on an open window must not re-select a tab")
        }
    }

    func testDockReopen_closedWindowComesBackOnTheTabItWasShowing() {
        XCTAssertEqual(ShellTab.dockReopenAction(hasEditorWindow: false, lastSelectedTab: .library),
                       .openRestoringTab(.library))
        XCTAssertEqual(ShellTab.dockReopenAction(hasEditorWindow: false, lastSelectedTab: .settings),
                       .openRestoringTab(.settings))
        XCTAssertEqual(ShellTab.dockReopenAction(hasEditorWindow: false, lastSelectedTab: .editor),
                       .openRestoringTab(.editor))
    }

    /// The remembered tab is in-process state, so a fresh launch has nothing to
    /// restore and lands on the Editor — `lastSelectedTab` starts there.
    func testDockReopen_freshLaunchDefaultsToEditor() {
        XCTAssertEqual(ShellTab.launchTab, .editor)
        XCTAssertEqual(ShellTab.dockReopenAction(hasEditorWindow: false,
                                                 lastSelectedTab: ShellTab.launchTab),
                       .openRestoringTab(.editor))
    }
}
