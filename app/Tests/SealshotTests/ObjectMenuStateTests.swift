import XCTest
@testable import Sealshot

/// Backing state for the menu-bar Edit items. SwiftUI menu commands can't use
/// AppKit's validateMenuItem, so enablement rides on published flags — the
/// same pattern as ExportMenuState.
@MainActor
final class ObjectMenuStateTests: XCTestCase {

    func testStartsDisabled() {
        let state = ObjectMenuState()
        XCTAssertFalse(state.hasSelection)
        XCTAssertFalse(state.hasFlippableSelection)
    }

    func testReflectsAnUpdate() {
        let state = ObjectMenuState()
        state.update(hasSelection: true, hasFlippableSelection: true)
        XCTAssertTrue(state.hasSelection)
        XCTAssertTrue(state.hasFlippableSelection)
    }

    /// A selection with no flippable members (e.g. badges only — the sole
    /// geometry `EditorState.isFlippable` excludes) enables Duplicate but not
    /// Flip.
    func testSelectionWithoutFlippableMembers() {
        let state = ObjectMenuState()
        state.update(hasSelection: true, hasFlippableSelection: false)
        XCTAssertTrue(state.hasSelection)
        XCTAssertFalse(state.hasFlippableSelection)
    }

    func testClearingSelection() {
        let state = ObjectMenuState()
        state.update(hasSelection: true, hasFlippableSelection: true)
        state.update(hasSelection: false, hasFlippableSelection: false)
        XCTAssertFalse(state.hasSelection)
        XCTAssertFalse(state.hasFlippableSelection)
    }
}
