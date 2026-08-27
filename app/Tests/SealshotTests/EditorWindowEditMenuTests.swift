import XCTest
import AppKit
@testable import Sealshot

/// The app's Edit menu (SwiftUI's default) dispatches the standard editing
/// selectors — undo:/redo:/cut:/copy:/paste:/selectAll:/delete: — through the
/// responder chain. `EditorWindow` is in that chain, so it must answer (and
/// validate) those selectors and route them to its existing editor closures;
/// otherwise the menu items stay greyed out even though the matching keyboard
/// shortcuts work via `performKeyEquivalent`.
@MainActor
final class EditorWindowEditMenuTests: XCTestCase {

    private func makeWindow() -> EditorWindow {
        EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                     title: "Test")
    }

    private func item(_ selector: Selector) -> NSMenuItem {
        NSMenuItem(title: "x", action: selector, keyEquivalent: "")
    }

    private func commandFEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f",
            isARepeat: false, keyCode: 3)!
    }

    // MARK: - Responds to the standard selectors

    func testRespondsToEditMenuSelectors() {
        let window = makeWindow()
        for name in ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "delete:"] {
            XCTAssertTrue(window.responds(to: NSSelectorFromString(name)),
                          "EditorWindow should answer \(name) for the Edit menu")
        }
    }

    // MARK: - Each selector routes to its closure

    func testCopyRoutesToOnCopy() {
        let window = makeWindow()
        var called = false
        window.onCopy = { called = true }
        window.perform(NSSelectorFromString("copy:"), with: nil)
        XCTAssertTrue(called)
    }

    func testCutRoutesToOnCut() {
        let window = makeWindow()
        var called = false
        window.onCut = { called = true; return true }
        window.perform(NSSelectorFromString("cut:"), with: nil)
        XCTAssertTrue(called)
    }

    func testPasteRoutesToOnPaste() {
        let window = makeWindow()
        var called = false
        window.onPaste = { called = true; return true }
        window.perform(NSSelectorFromString("paste:"), with: nil)
        XCTAssertTrue(called)
    }

    func testUndoRoutesToOnUndo() {
        let window = makeWindow()
        var called = false
        window.onUndo = { called = true }
        window.perform(NSSelectorFromString("undo:"), with: nil)
        XCTAssertTrue(called)
    }

    func testRedoRoutesToOnRedo() {
        let window = makeWindow()
        var called = false
        window.onRedo = { called = true }
        window.perform(NSSelectorFromString("redo:"), with: nil)
        XCTAssertTrue(called)
    }

    func testCommandFRoutesToFindInImage() {
        let window = makeWindow()
        var called = false
        window.onFindInImage = { called = true; return true }

        XCTAssertTrue(window.performKeyEquivalent(with: commandFEvent(for: window)))
        XCTAssertTrue(called)
    }

    func testSelectAllRoutesToOnSelectAll() {
        let window = makeWindow()
        var called = false
        window.onSelectAll = { called = true }
        window.perform(NSSelectorFromString("selectAll:"), with: nil)
        XCTAssertTrue(called)
    }

    /// Edit→Delete removes the selected annotation objects (onDeleteSelection),
    /// NOT the whole capture file (onDeleteCurrent / ⌘⌫).
    func testDeleteRoutesToOnDeleteSelection() {
        let window = makeWindow()
        var deletedSelection = false
        var deletedCurrent = false
        window.onDeleteSelection = { deletedSelection = true }
        window.onDeleteCurrent = { deletedCurrent = true }
        window.perform(NSSelectorFromString("delete:"), with: nil)
        XCTAssertTrue(deletedSelection, "Edit→Delete should delete the selected objects")
        XCTAssertFalse(deletedCurrent, "Edit→Delete must not delete the capture file")
    }

    // MARK: - Validation enables only when a handler is wired

    func testValidatesWhenHandlerPresent() {
        let window = makeWindow()
        window.onCopy = {}
        window.onUndo = {}
        window.onSelectAll = {}
        window.onDeleteSelection = {}
        XCTAssertTrue(window.validateMenuItem(item(NSSelectorFromString("copy:"))))
        XCTAssertTrue(window.validateMenuItem(item(NSSelectorFromString("undo:"))))
        XCTAssertTrue(window.validateMenuItem(item(NSSelectorFromString("selectAll:"))))
        XCTAssertTrue(window.validateMenuItem(item(NSSelectorFromString("delete:"))))
    }

    func testDisabledWhenHandlerAbsent() {
        let window = makeWindow()
        // No closures set.
        XCTAssertFalse(window.validateMenuItem(item(NSSelectorFromString("copy:"))))
        XCTAssertFalse(window.validateMenuItem(item(NSSelectorFromString("undo:"))))
        XCTAssertFalse(window.validateMenuItem(item(NSSelectorFromString("delete:"))))
    }

    // MARK: - Validation reflects real availability (consistency with the
    // editor toolbar): a handler present but nothing to act on stays disabled.

    func testRedoDisabledWhenNothingToRedo() {
        let window = makeWindow()
        window.onRedo = {}
        window.canRedo = { false }
        XCTAssertFalse(window.validateMenuItem(item(NSSelectorFromString("redo:"))),
                       "Redo should be disabled when there is nothing to redo")
    }

    func testRedoEnabledWhenSomethingToRedo() {
        let window = makeWindow()
        window.onRedo = {}
        window.canRedo = { true }
        XCTAssertTrue(window.validateMenuItem(item(NSSelectorFromString("redo:"))))
    }

    func testUndoDisabledWhenNothingToUndo() {
        let window = makeWindow()
        window.onUndo = {}
        window.canUndo = { false }
        XCTAssertFalse(window.validateMenuItem(item(NSSelectorFromString("undo:"))))
    }

    func testCutDisabledWhenNoSelection() {
        let window = makeWindow()
        window.onCut = { true }
        window.canCut = { false }
        XCTAssertFalse(window.validateMenuItem(item(NSSelectorFromString("cut:"))))
    }

    func testDeleteDisabledWhenNoSelection() {
        let window = makeWindow()
        window.onDeleteSelection = {}
        window.canDeleteSelection = { false }
        XCTAssertFalse(window.validateMenuItem(item(NSSelectorFromString("delete:"))))
    }

    func testCopyDisabledWhenNothingToCopy() {
        let window = makeWindow()
        window.onCopy = {}
        window.canCopy = { false }
        XCTAssertFalse(window.validateMenuItem(item(NSSelectorFromString("copy:"))))
    }

    /// Backward compatible: with a handler but no predicate, the item is enabled.
    func testEnabledWhenHandlerPresentAndNoPredicate() {
        let window = makeWindow()
        window.onRedo = {}
        XCTAssertTrue(window.validateMenuItem(item(NSSelectorFromString("redo:"))))
    }
}
