import AppKit
import XCTest
@testable import Sealshot

final class FloatingPinPolicyTests: XCTestCase {

    func testDefault_isPinned_matchingWhatThePanelShippedWith() {
        XCTAssertEqual(FloatingPinPolicy.defaultState, .pinned)
    }

    func testToggle_flipsBothWays() {
        XCTAssertEqual(FloatingPinState.pinned.toggled, .unpinned)
        XCTAssertEqual(FloatingPinState.unpinned.toggled, .pinned)
    }

    /// A pinned panel is already above the editor; only an unpinned one has to
    /// be pulled forward when the editor comes up.
    func testOnlyAnUnpinnedPanelFollowsTheEditor() {
        XCTAssertFalse(FloatingPinPolicy.followsEditor(.pinned))
        XCTAssertTrue(FloatingPinPolicy.followsEditor(.unpinned))
    }

    /// Window levels are absolute. While the editor is promoted to `.floating`
    /// — which is exactly when it becomes key on every programmatic raise — a
    /// `.normal` panel ordered above it does not move at all, so the ride has
    /// to be re-asserted once the promotion ends.
    func testOrderingAbove_cannotTakeEffectWhileTheEditorOutranksThePanel() {
        XCTAssertFalse(FloatingPinPolicy.orderAboveTakesEffect(
            panelLevel: NSWindow.Level.normal.rawValue,
            editorLevel: NSWindow.Level.floating.rawValue))
    }

    func testOrderingAbove_takesEffectOnceTheEditorIsBackAtTheSameLevel() {
        XCTAssertTrue(FloatingPinPolicy.orderAboveTakesEffect(
            panelLevel: NSWindow.Level.normal.rawValue,
            editorLevel: NSWindow.Level.normal.rawValue))
        // A pinned panel outranks the editor outright.
        XCTAssertTrue(FloatingPinPolicy.orderAboveTakesEffect(
            panelLevel: NSWindow.Level.floating.rawValue,
            editorLevel: NSWindow.Level.normal.rawValue))
    }

    func testGlyphAndTooltip_readTheStateFromTheButtonAlone() {
        XCTAssertEqual(FloatingPinState.pinned.symbolName, "pin.fill")
        XCTAssertEqual(FloatingPinState.unpinned.symbolName, "pin.slash")
        XCTAssertNotEqual(FloatingPinState.pinned.tooltip, FloatingPinState.unpinned.tooltip)
    }

    func testPreference_absentReadsAsPinned_andRoundTrips() {
        let suite = "FloatingPinPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let pref = FloatingPinPreference(defaults: defaults)
        XCTAssertEqual(pref.state, .pinned)

        pref.state = .unpinned
        XCTAssertEqual(FloatingPinPreference(defaults: defaults).state, .unpinned)

        pref.state = .pinned
        XCTAssertEqual(FloatingPinPreference(defaults: defaults).state, .pinned)
    }
}
