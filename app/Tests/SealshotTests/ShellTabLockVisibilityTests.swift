import XCTest
@testable import Sealshot

/// The lock boundary's UI half: while the encryption session is locked, no
/// tab's content may render.
///
/// This existed only as three `isHidden` assignments inside
/// `EditorWindowController.selectTab`, and only the editor column carried the
/// lock term — Library and Settings relied on the lock overlay covering them.
/// That was a weaker guarantee than being hidden, and it broke outright when a
/// tab visited for the first time while locked was added to the container
/// *after* the overlay and so drew above it.
final class ShellTabLockVisibilityTests: XCTestCase {

    /// The invariant, stated once: locked hides everything, whatever is selected.
    func test_whileLocked_noTabRenders() {
        for selected in ShellTab.allCases {
            for tab in ShellTab.allCases {
                XCTAssertTrue(
                    ShellTab.isContentHidden(tab, selected: selected, locked: true),
                    "\(tab) must be hidden while locked (selected: \(selected))")
            }
        }
    }

    func test_whileUnlocked_onlyTheSelectedTabRenders() {
        for selected in ShellTab.allCases {
            for tab in ShellTab.allCases {
                XCTAssertEqual(
                    ShellTab.isContentHidden(tab, selected: selected, locked: false),
                    tab != selected,
                    "unlocked: \(tab) visible only when selected (selected: \(selected))")
            }
        }
    }

    /// The reported bug: locked + a capture shortcut routed to Settings, which
    /// rendered because only the editor column was lock-gated.
    func test_settingsIsHiddenWhileLocked_evenWhenSelected() {
        XCTAssertTrue(ShellTab.isContentHidden(.settings, selected: .settings, locked: true))
    }

    /// Library rides the same mechanism and shows capture filenames and dates.
    func test_libraryIsHiddenWhileLocked_evenWhenSelected() {
        XCTAssertTrue(ShellTab.isContentHidden(.library, selected: .library, locked: true))
    }

    /// Guards against a future edit that special-cases one tab back out of the
    /// rule: every case of the enum is covered, so adding a tab without
    /// considering the lock fails here rather than shipping.
    func test_everyTabIsCoveredByTheRule() {
        XCTAssertEqual(ShellTab.allCases.count, 3, "a new tab must be added to the lock rule")
        XCTAssertTrue(ShellTab.allCases.allSatisfy {
            ShellTab.isContentHidden($0, selected: $0, locked: true)
        })
    }
}
