import XCTest
import KeyboardShortcuts
@testable import Sealshot

/// Per-layout memory for the Settings ▸ Shortcuts picker.
///
/// The behaviour being pinned: an edit belongs to the layout it was made under,
/// switching layouts restores what you left there, and neither layout can
/// silently overwrite the other's keys. Before this, choosing a layout wrote its
/// whole table, so glancing at the other tab cost you every customization.
///
/// Everything runs against an isolated UserDefaults suite and an injected
/// binding dictionary — the test host shares the app's UserDefaults, so writing
/// through KeyboardShortcuts here would rebind the USER's real keys.
final class ShortcutLayoutStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Stands in for the live shortcut storage.
    private var live: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut?] = [:]

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutLayoutStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        live = [:]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> ShortcutLayoutStore {
        ShortcutLayoutStore(defaults: defaults,
                            set: { shortcut, name in self.live[name] = shortcut },
                            get: { name in self.live[name] ?? nil })
    }

    private let edited = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])

    // MARK: Selection

    func testSelection_defaultsToLetters_whenNothingIsStoredAndNothingMatches() {
        XCTAssertEqual(makeStore().selected, .letters)
    }

    /// An install that predates the store has keys but no stored selection.
    /// Reading the keys beats telling a numbers user they are on Letters.
    func testSelection_infersTheLayoutTheLiveKeysAlreadyMatch() {
        for (name, shortcut) in ShortcutLayout.numbers.bindings { live[name] = shortcut }
        XCTAssertEqual(makeStore().selected, .numbers)
    }

    func testSelection_persists() {
        makeStore().select(.numbers)
        XCTAssertEqual(makeStore().selected, .numbers, "a new store must read the stored choice")
    }

    // MARK: The behaviour this whole type exists for

    func testEditUnderOneLayout_survivesASwitchAwayAndBack() {
        let store = makeStore()
        store.select(.numbers)
        store.record(edited, for: .captureUnified)

        store.select(.letters)
        XCTAssertEqual(live[.captureUnified], ShortcutLayout.letters.bindings[.captureUnified],
                       "letters must show its own key, not the numbers edit")

        store.select(.numbers)
        XCTAssertEqual(live[.captureUnified], edited,
                       "the edit made under numbers came back")
    }

    func testEditUnderOneLayout_leavesTheOtherLayoutUntouched() {
        let store = makeStore()
        store.select(.numbers)
        store.record(edited, for: .captureUnified)

        XCTAssertEqual(store.bindings(for: .letters)[.captureUnified],
                       ShortcutLayout.letters.bindings[.captureUnified])
    }

    func testBothLayouts_rememberTheirOwnEditsAtTheSameTime() {
        let store = makeStore()
        let lettersEdit = KeyboardShortcuts.Shortcut(.j, modifiers: [.command, .control])

        store.select(.letters)
        store.record(lettersEdit, for: .captureScroll)
        store.select(.numbers)
        store.record(edited, for: .captureScroll)

        store.select(.letters)
        XCTAssertEqual(live[.captureScroll], lettersEdit)
        store.select(.numbers)
        XCTAssertEqual(live[.captureScroll], edited)
    }

    /// A cleared key is a decision, not an absence: it must stay cleared across a
    /// switch rather than springing back to the table's value.
    func testClearingAKey_isRememberedAsCleared() {
        let store = makeStore()
        store.select(.numbers)
        store.record(nil, for: .captureDelayed)

        store.select(.letters)
        store.select(.numbers)
        XCTAssertEqual(live[.captureDelayed], KeyboardShortcuts.Shortcut?.none)
    }

    /// Editor, Library and lock mean the same thing in both layouts, so they are
    /// stored once by KeyboardShortcuts. Recording them per layout would invent a
    /// difference and then restore it over the user's key on every switch.
    func testUngovernedNames_areNotRecordedPerLayout() {
        let store = makeStore()
        store.select(.numbers)
        store.record(edited, for: .openEditor)

        XCTAssertNil(store.bindings(for: .numbers)[.openEditor] ?? nil,
                     "openEditor is not a layout key")
        store.select(.letters)
        XCTAssertNil(live[.openEditor] ?? nil, "switching must not touch it either")
    }

    // MARK: Reset

    func testResetOverrides_restoresThatLayoutsTable_andKeepsTheSelection() {
        let store = makeStore()
        store.select(.numbers)
        store.record(edited, for: .captureUnified)

        store.resetOverrides(for: .numbers)

        XCTAssertEqual(live[.captureUnified], ShortcutLayout.numbers.bindings[.captureUnified])
        XCTAssertEqual(store.selected, .numbers, "Reset means defaults, not a different layout")
    }

    func testResetOverrides_leavesTheOtherLayoutsEditsAlone() {
        let store = makeStore()
        let lettersEdit = KeyboardShortcuts.Shortcut(.j, modifiers: [.command, .control])
        store.select(.letters)
        store.record(lettersEdit, for: .captureScroll)
        store.select(.numbers)
        store.record(edited, for: .captureScroll)

        store.resetOverrides(for: .numbers)

        XCTAssertEqual(store.bindings(for: .letters)[.captureScroll], lettersEdit)
    }

    func testResetEverything_clearsBothLayoutsAndReturnsToLetters() {
        let store = makeStore()
        store.select(.numbers)
        store.record(edited, for: .captureUnified)
        store.select(.letters)
        store.record(edited, for: .captureScroll)

        store.resetEverything()

        XCTAssertEqual(store.selected, .letters)
        XCTAssertEqual(store.bindings(for: .letters)[.captureScroll],
                       ShortcutLayout.letters.bindings[.captureScroll])
        XCTAssertEqual(store.bindings(for: .numbers)[.captureUnified],
                       ShortcutLayout.numbers.bindings[.captureUnified])
        XCTAssertEqual(live[.captureScroll], ShortcutLayout.letters.bindings[.captureScroll])
    }

    // MARK: Storage hygiene

    func testStoredOverrides_ignoreNamesTheLayoutNoLongerGoverns() {
        // A retired action must not resurrect a binding nothing can reach.
        let raw = ["captureUnified": KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option]),
                   "someRetiredAction": KeyboardShortcuts.Shortcut(.p, modifiers: [.command])]
        defaults.set(try? JSONEncoder().encode(raw),
                     forKey: ShortcutLayoutStore.overridesKey(.numbers))

        let merged = makeStore().bindings(for: .numbers)
        XCTAssertEqual(merged.count, ShortcutLayout.governedNames.count)
        XCTAssertEqual(merged[.captureUnified], raw["captureUnified"])
    }

    func testApplyingALayout_writesEveryGovernedName() {
        // A name missing from the write would keep its previous layout's key.
        makeStore().select(.numbers)
        for name in ShortcutLayout.governedNames {
            XCTAssertNotNil(live[name] ?? nil, "\(name.rawValue) was not written")
        }
    }
}
