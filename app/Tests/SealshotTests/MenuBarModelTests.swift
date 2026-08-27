import XCTest
@testable import Sealshot

final class MenuBarModelTests: XCTestCase {

    private func actions(_ items: [MenuBarItemSpec]) -> [MenuBarAction] {
        items.compactMap(\.action)
    }

    /// Direct build, updates ready, Enhanced security on + unlocked, image on
    /// the clipboard — every conditional row visible and enabled.
    private let full = MenuBarContext(
        updatesSupported: true, updateCheckReady: true,
        encryptionEnabled: true, sessionUnlocked: true,
        clipboardHasImage: true)

    // MARK: Icon

    func testIcon_idle_isAppIconMono() {
        XCTAssertEqual(MenuBarModel.icon(for: .idle), .appIconMono)
    }

    func testIcon_recording_isRecordingDot() {
        XCTAssertEqual(MenuBarModel.icon(for: .recording(paused: false, elapsedSeconds: 0)), .recordingDot)
        XCTAssertEqual(MenuBarModel.icon(for: .recording(paused: true, elapsedSeconds: 12)), .recordingDot)
    }

    // MARK: Idle menu

    /// Every menu icon must be a symbol that EXISTS. A misremembered name —
    /// `arrow.clockwise.viewfinder`, which sounds real and isn't — resolves to
    /// nil and the row simply renders with no icon, which looks like the icon
    /// was never wired up rather than like a typo.
    func testEveryMenuIcon_resolvesToARealSymbol() {
        let actions: [MenuBarAction] = [
            .captureUnified, .captureSaveAs, .captureFullscreen, .captureDelayed,
            .captureScroll, .captureLive, .captureRepeat,
            .recordScreen, .recordSelection, .pauseResume, .stopRecording,
            .openEditor, .openLibrary, .newFromClipboard, .importImage,
            .settings, .checkForUpdates, .lockNow, .quit,
        ]
        for action in actions {
            let name = MenuBarModel.defaultIcon(for: action)
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                            "\(action) uses \"\(name)\", which is not a real SF Symbol")
        }
    }

    func testIdleMenu_hasExpectedActionsInOrder() {
        let acts = actions(MenuBarModel.items(for: .idle, context: full))
        XCTAssertEqual(acts, [
            .captureUnified, .captureSaveAs,
            .captureFullscreen, .captureDelayed, .captureScroll, .captureLive, .captureRepeat,
            .recordScreen, .recordSelection,
            .openEditor, .openLibrary, .newFromClipboard, .importImage,
            .settings, .checkForUpdates, .lockNow,
            .quit,
        ])
    }

    func testIdleMenu_hasNoRecordingControls() {
        let acts = actions(MenuBarModel.items(for: .idle, context: full))
        XCTAssertFalse(acts.contains(.pauseResume))
        XCTAssertFalse(acts.contains(.stopRecording))
    }

    func testIdleMenu_separatorsGroupSections() {
        let items = MenuBarModel.items(for: .idle, context: full)
        func index(_ action: MenuBarAction) -> Int { items.firstIndex { $0.action == action }! }
        // The headline capture pair sits at the top, then a separator.
        XCTAssertEqual(items.first?.action, .captureUnified)
        XCTAssertTrue(items[index(.captureSaveAs) + 1].isSeparator)
        // Separators before the record group, the open group, the app group,
        // and Quit.
        XCTAssertTrue(items[index(.recordScreen) - 1].isSeparator)
        XCTAssertTrue(items[index(.openEditor) - 1].isSeparator)
        XCTAssertTrue(items[index(.settings) - 1].isSeparator)
        XCTAssertTrue(items[index(.quit) - 1].isSeparator)
    }

    // MARK: Titles (user-picked naming)

    func testIdleMenu_titles() {
        let items = MenuBarModel.items(for: .idle, context: full)
        func title(_ action: MenuBarAction) -> String { items.first { $0.action == action }!.title }
        XCTAssertEqual(title(.captureUnified), "Smart Capture")
        XCTAssertEqual(title(.captureSaveAs), "Save As Capture…")
        XCTAssertEqual(title(.recordScreen), "Record Full Screen")
        XCTAssertEqual(title(.recordSelection), "Record Selection")
        XCTAssertEqual(title(.openLibrary), "Open Library")
        XCTAssertEqual(title(.newFromClipboard), "New from Clipboard")
        XCTAssertEqual(title(.importImage), "Import Image…")
        XCTAssertEqual(title(.checkForUpdates), "Check for Updates…")
        XCTAssertEqual(title(.lockNow), "Lock Now")
    }

    // MARK: Conditional rows

    func testLockNow_hiddenWhileEncryptionOff() {
        var ctx = full; ctx.encryptionEnabled = false
        XCTAssertFalse(actions(MenuBarModel.items(for: .idle, context: ctx)).contains(.lockNow))
    }

    func testLockNow_disabledWhileAlreadyLocked() {
        var ctx = full; ctx.sessionUnlocked = false
        let row = MenuBarModel.items(for: .idle, context: ctx).first { $0.action == .lockNow }
        XCTAssertNotNil(row)
        XCTAssertFalse(row!.enabled)
    }

    func testCheckForUpdates_hiddenWhenUnsupported() {
        var ctx = full; ctx.updatesSupported = false
        XCTAssertFalse(actions(MenuBarModel.items(for: .idle, context: ctx)).contains(.checkForUpdates))
    }

    func testCheckForUpdates_disabledUntilReady() {
        var ctx = full; ctx.updateCheckReady = false
        let row = MenuBarModel.items(for: .idle, context: ctx).first { $0.action == .checkForUpdates }
        XCTAssertNotNil(row)
        XCTAssertFalse(row!.enabled)
    }

    func testNewFromClipboard_disabledWhenClipboardHasNoImage() {
        func row(_ ctx: MenuBarContext) -> MenuBarItemSpec {
            MenuBarModel.items(for: .idle, context: ctx).first { $0.action == .newFromClipboard }!
        }
        XCTAssertTrue(row(full).enabled)   // image present
        var empty = full; empty.clipboardHasImage = false
        XCTAssertFalse(row(empty).enabled, "no image on clipboard → grayed out")
    }

    // MARK: Recording menu

    func testRecordingMenu_showsControlsNotCaptureActions() {
        let acts = actions(MenuBarModel.items(for: .recording(paused: false, elapsedSeconds: 23)))
        XCTAssertEqual(acts, [.pauseResume, .stopRecording])
    }

    func testRecordingMenu_headerShowsElapsed() {
        let items = MenuBarModel.items(for: .recording(paused: false, elapsedSeconds: 23))
        // First row is a disabled header carrying the elapsed time.
        XCTAssertNil(items[0].action)
        XCTAssertFalse(items[0].enabled)
        XCTAssertTrue(items[0].title.contains("0:23"), "header was \(items[0].title)")
    }

    func testRecordingMenu_pauseTitleReflectsState() {
        let running = MenuBarModel.items(for: .recording(paused: false, elapsedSeconds: 5))
            .first { $0.action == .pauseResume }!
        XCTAssertEqual(running.title, "Pause")
        let paused = MenuBarModel.items(for: .recording(paused: true, elapsedSeconds: 5))
            .first { $0.action == .pauseResume }!
        XCTAssertEqual(paused.title, "Resume")
    }

    // MARK: Item icons

    func testEveryActionableItemHasIcon() {
        var specs = MenuBarModel.items(for: .idle, context: full)
        specs += MenuBarModel.items(for: .recording(paused: false, elapsedSeconds: 0))
        for spec in specs where spec.action != nil {
            XCTAssertFalse(spec.icon?.isEmpty ?? true, "\(spec.title) must have a non-empty icon")
        }
    }

    func testPauseResumeIconReflectsState() {
        let running = MenuBarModel.items(for: .recording(paused: false, elapsedSeconds: 0))
            .first { $0.action == .pauseResume }!
        let paused = MenuBarModel.items(for: .recording(paused: true, elapsedSeconds: 0))
            .first { $0.action == .pauseResume }!
        XCTAssertNotEqual(running.icon, paused.icon, "Pause and Resume show different icons")
    }

    // MARK: Elapsed formatting

    func testElapsedString() {
        XCTAssertEqual(MenuBarModel.elapsedString(0), "0:00")
        XCTAssertEqual(MenuBarModel.elapsedString(5), "0:05")
        XCTAssertEqual(MenuBarModel.elapsedString(65), "1:05")
        XCTAssertEqual(MenuBarModel.elapsedString(600), "10:00")
    }
}
