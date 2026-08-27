import XCTest
import KeyboardShortcuts
@testable import Sealshot

/// The letters/numbers layout toggle. Everything here runs against injected
/// dictionaries — the test host shares the app's UserDefaults, so touching
/// the real KeyboardShortcuts storage would rebind the USER's keys mid-test.
final class ShortcutLayoutTests: XCTestCase {

    /// Both layouts must bind exactly the governed names: a name bound in one
    /// layout but missing from the other would keep its old key across a
    /// switch and quietly corrupt the layout it lands in.
    func testEveryLayout_bindsExactlyTheGovernedNames() {
        for layout in ShortcutLayout.allCases {
            XCTAssertEqual(Set(layout.bindings.keys), Set(ShortcutLayout.governedNames),
                           "\(layout) drifts from governedNames")
        }
    }

    func testNoLayout_assignsTheSameKeyTwice() {
        for layout in ShortcutLayout.allCases {
            let combos = layout.bindings.values.map { "\($0)" }
            XCTAssertEqual(combos.count, Set(combos).count,
                           "\(layout) binds one combo to two actions")
        }
    }

    /// The letters table IS the shipped defaults, spelled out. If a default
    /// changes without this table, switching layouts and back would silently
    /// change a user's keys.
    func testLettersLayout_matchesTheShippedDefaults() {
        for (name, shortcut) in ShortcutLayout.letters.bindings {
            XCTAssertEqual(shortcut, name.defaultShortcut,
                           "\(name.rawValue): letters table disagrees with the code default")
        }
    }

    /// The whole point of the numbers layout: ⌘⇧ + the digit row, with 3/4/5
    /// meaning what macOS means by them.
    func testNumbersLayout_isCommandShiftDigitsWithSystemMeanings() {
        let digits: Set<KeyboardShortcuts.Key> = [.zero, .one, .two, .three, .four,
                                                  .five, .six, .seven, .eight, .nine]
        for (name, shortcut) in ShortcutLayout.numbers.bindings {
            XCTAssertEqual(shortcut.modifiers, [.command, .shift], "\(name.rawValue)")
            XCTAssertTrue(shortcut.key.map(digits.contains) ?? false,
                          "\(name.rawValue) is not on the digit row")
        }
        let table = ShortcutLayout.numbers.bindings
        XCTAssertEqual(table[.captureFullscreen]?.key, .three, "system's full-screen key")
        XCTAssertEqual(table[.captureUnified]?.key, .four, "system's select-area key")
        XCTAssertEqual(table[.recordToggle]?.key, .five, "system's recording toolbar key")
    }

    // MARK: Apply / match round-trip (against a dictionary)

    func testApplyThenCurrent_roundTripsBothLayouts() {
        var store: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
        for layout in ShortcutLayout.allCases {
            layout.apply { store[$1] = $0 }
            XCTAssertEqual(ShortcutLayout.current(get: { store[$0] }), layout)
        }
    }

    /// One hand-edited key means neither layout: the Settings picker shows
    /// Custom rather than lying about which layout is active.
    func testASingleCustomizedKey_matchesNeitherLayout() {
        var store: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
        ShortcutLayout.numbers.apply { store[$1] = $0 }
        store[.captureRepeat] = .init(.j, modifiers: [.command, .shift])
        XCTAssertNil(ShortcutLayout.current(get: { store[$0] }))
    }

    /// Applying a layout over a customized set replaces the customization —
    /// half-applied layouts are a state nobody can reason about.
    func testApply_overwritesCustomizations() {
        var store: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
        store[.captureRepeat] = .init(.j, modifiers: [.command, .shift])
        ShortcutLayout.letters.apply { store[$1] = $0 }
        XCTAssertEqual(store[.captureRepeat],
                       ShortcutLayout.letters.bindings[.captureRepeat])
    }
}

/// Reading (never writing) whether macOS still owns ⌘⇧3/4/5 — the keys the
/// numbers layout wants. While the system holds one, Sealshot never receives
/// the event, so the binding is silently dead; the Settings warning this
/// feeds is what separates "dead key" from "broken app".
final class SystemScreenshotHotkeysTests: XCTestCase {
    func testNoEntries_meansAllEnabled() {
        // The plist only records deviations; absence = the default = on.
        XCTAssertEqual(SystemScreenshotHotkeys.enabledIDs(in: [:]),
                       SystemScreenshotHotkeys.allIDs)
    }

    func testDisabledEntries_areReportedDisabled() {
        let dict: [String: Any] = [
            "28": ["enabled": false], "30": ["enabled": false], "184": ["enabled": false],
        ]
        XCTAssertEqual(SystemScreenshotHotkeys.enabledIDs(in: dict), [])
    }

    func testMixedAndMalformedEntries() {
        let dict: [String: Any] = [
            "28": ["enabled": true],       // explicitly on
            "30": ["enabled": false],      // off
            "184": ["value": "junk"],      // malformed: treat as on (the default)
        ]
        XCTAssertEqual(SystemScreenshotHotkeys.enabledIDs(in: dict), ["28", "184"])
    }

    /// Unrelated symbolic hotkeys (Spotlight, Mission Control…) are ignored.
    func testUnrelatedHotkeys_doNotLeakIn() {
        let dict: [String: Any] = ["64": ["enabled": true], "28": ["enabled": false],
                                   "30": ["enabled": false], "184": ["enabled": false]]
        XCTAssertEqual(SystemScreenshotHotkeys.enabledIDs(in: dict), [])
    }
}
