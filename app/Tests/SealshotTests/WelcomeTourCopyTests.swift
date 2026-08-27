import XCTest
import KeyboardShortcuts
@testable import Sealshot

@MainActor
final class WelcomeTourCopyTests: XCTestCase {

    func test_chipsSplitModifiersButKeepTheKeyWhole() {
        XCTAssertEqual(WelcomeTourCopy.chips(for: "⇧⌘C"), ["⇧", "⌘", "C"])
        // A multi-character key name stays ONE chip. The tour's old
        // per-character split would have rendered S, p, a, c, e.
        XCTAssertEqual(WelcomeTourCopy.chips(for: "⇧⌘Space"), ["⇧", "⌘", "Space"])
        XCTAssertEqual(WelcomeTourCopy.chips(for: "F"), ["F"])
        XCTAssertEqual(WelcomeTourCopy.chips(for: ""), [])
    }

    func test_chipsFollowTheLiveBinding() {
        // The point of the whole helper: a user who rebinds a shortcut must see
        // THEIR keys in the tour, not the combo that shipped.
        let name = KeyboardShortcuts.Name.captureScroll
        let original = name.shortcut
        defer { KeyboardShortcuts.setShortcut(original, for: name) }

        KeyboardShortcuts.setShortcut(.init(.j, modifiers: [.command, .option]), for: name)

        let chips = WelcomeTourCopy.shortcutChips(for: name)
        XCTAssertEqual(chips.last, "J")
        XCTAssertTrue(chips.contains("⌘"))
        XCTAssertTrue(chips.contains("⌥"))
    }

    func test_scrollingCaptureNoLongerAdvertisesTheLockNowCombo() {
        // ⌘⇧L became "Lock now" (CaptureShortcuts.swift), but the tour kept
        // teaching it for scrolling capture — so a first-run user following the
        // tour locked their library instead of capturing.
        XCTAssertNotEqual(Set(WelcomeTourCopy.shortcutChips(for: .captureScroll)),
                          Set(["⌘", "⇧", "L"]),
                          "scrolling capture must not advertise the Lock now combo")
        XCTAssertEqual(Set(WelcomeTourCopy.shortcutChips(for: .lockNow)),
                       Set(["⌘", "⇧", "L"]))
    }

    func test_everyShortcutTheTourAdvertisesResolves() {
        // An unbound name would render an empty chip row — a blank space where
        // the tour promises a shortcut.
        for name in WelcomeTourCopy.advertisedShortcuts {
            XCTAssertFalse(WelcomeTourCopy.shortcutChips(for: name).isEmpty,
                           "\(name.rawValue) has no shortcut to show")
        }
    }

    func test_freeUseRowIsDirectEditionOnly() {
        // A Mac App Store copy was already paid for — telling that buyer the
        // app is free would be a strange greeting.
        XCTAssertTrue(WelcomeTourCopy.showsFreeUseRow(edition: .direct))
        XCTAssertFalse(WelcomeTourCopy.showsFreeUseRow(edition: .mas))
    }

    /// The welcome tour is the first promise the app makes. It must not promise
    /// a trial — there isn't one — and it must not imply an expiry.
    func test_freeUseCopyPromisesNoTrialAndNoExpiry() {
        let copy = (WelcomeTourCopy.freeUseTitle + " " + WelcomeTourCopy.freeUseDetail).lowercased()
        XCTAssertFalse(copy.contains("trial"), "there is no trial: \(copy)")
        XCTAssertFalse(copy.contains("days left"))
        XCTAssertTrue(copy.contains("nothing expires"))
    }
}
