import XCTest
import KeyboardShortcuts
@testable import Sealshot

final class ShortcutCatalogTests: XCTestCase {

    private let combo = KeyboardShortcuts.Shortcut(.c, modifiers: [.command, .shift])

    func testConflict_findsTheOtherRowHoldingTheCombo() {
        let owner = ShortcutCatalog.conflictingTitle(
            for: combo, excluding: .openLibrary,
            current: { $0 == .captureUnified ? self.combo : nil })
        XCTAssertEqual(owner, "Unified capture")
    }

    func testConflict_ignoresTheRowBeingRecorded() {
        // The row being edited already stores the new value by the time
        // onChange fires — it must never conflict with itself.
        let owner = ShortcutCatalog.conflictingTitle(
            for: combo, excluding: .openLibrary,
            current: { $0 == .openLibrary ? self.combo : nil })
        XCTAssertNil(owner)
    }

    func testConflict_nilWhenComboIsFree() {
        XCTAssertNil(ShortcutCatalog.conflictingTitle(
            for: combo, excluding: .openLibrary, current: { _ in nil }))
    }

    func testCatalog_coversEveryRowExactlyOnce() {
        let names = ShortcutCatalog.all.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "no duplicate names")
        XCTAssertEqual(names.count, 14, "one entry per Settings shortcut row")
    }
}
