import AppKit
import XCTest
@testable import Sealshot

/// A library listing entry as the panel's provider returns it — the same
/// `StripItem` the editor strip renders.
private func stripItem(_ path: String, video: Bool = false) -> StripItem {
    StripItem(url: URL(fileURLWithPath: path), captureDate: Date(),
              displayName: (path as NSString).lastPathComponent, isVideo: video)
}

@MainActor
final class FloatingCaptureControllerTests: XCTestCase {

    /// A point genuinely past the LEFT edge of every attached display.
    ///
    /// `visible.minX - 300` looks like it is off-screen and is not: on a desk
    /// with a monitor to the left of the main one it lands squarely ON that
    /// monitor, `dockEdge` sees no overshoot, and every docking test quietly
    /// stops testing docking. Twenty-one of them failed the moment a second
    /// display was plugged in.
    private var pastLeftEdgeOfEverything: CGFloat {
        leftmostVisibleFrame.minX - 400
    }

    /// The display a panel shoved past `pastLeftEdgeOfEverything` docks to —
    /// which is the leftmost one, NOT `NSScreen.main`. Assertions have to
    /// compare against the screen the line actually landed on.
    private var leftmostVisibleFrame: CGRect {
        NSScreen.screens.min { $0.frame.minX < $1.frame.minX }
            .map(\.visibleFrame) ?? .zero
    }

    /// Each test gets its own defaults. The test host shares the app's
    /// container, so panel state persisted by one test used to leak into the
    /// next — a dock made here, restored there, and assertions failing in a
    /// test that never touched docking.
    private var suite: UserDefaults!

    private func makeController() -> FloatingCaptureController {
        let c = FloatingCaptureController(defaults: suite)
        // The tooltip-wake monitors watch the REAL mouse: a hand resting on
        // the trackpad woke suppression between a test's act and its assert.
        c.installsTooltipWakeMonitors = false
        return c
    }

    override func setUp() {
        super.setUp()
        let name = "FloatingCaptureControllerTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: name)!
        // The test host shares the app's defaults, so state a previous test
        // persisted would leak into the next one. Docking now writes a
        // remembered edge — leaving it set makes every later `show()` restore
        // a dock, which is not what most of these tests are about.
    }

    // MARK: Rendering

    func testFaceButton_startsAsSmartCapture() {
        let c = makeController()
        XCTAssertEqual(c.faceButton.tooltipText, FloatingCaptureKind.unified.title)
    }

    func testShowAndHide_toggleVisibility() {
        let c = makeController()
        XCTAssertFalse(c.isVisible)
        c.show()
        XCTAssertTrue(c.isVisible)
        c.hide()
        XCTAssertFalse(c.isVisible)
    }

    /// The count is hidden for now in EVERY size — it may return later, so the
    /// model keeps ticking underneath.
    func testCountLabel_isAlwaysHiddenForNow() {
        let c = makeController()
        for size in [FloatingPanelSize.compact, .standard, .strip] {
            c.size = size
            XCTAssertTrue(c.countLabel.isHidden, "count must stay hidden in \(size)")
        }
        c.captureLanded()
        XCTAssertTrue(c.countLabel.isHidden, "a landed capture must not reveal it")
    }

    /// The panel widened 50% by request — but it is still a small panel, not
    /// the editor. Guard both directions.
    func testPanel_holdsItsWidenedBaseline() {
        let c = makeController()
        c.show()
        XCTAssertGreaterThanOrEqual(c.panelFrameForTesting.width,
                                    FloatingCaptureController.panelMinWidth - 1)
        XCTAssertLessThanOrEqual(c.panelFrameForTesting.width, 320,
                                 "a future row must not quietly balloon the panel")
    }

    // MARK: Actions

    func testFaceButton_performsTheFaceKind() {
        let c = makeController()
        var performed: [FloatingCaptureKind] = []
        c.perform = { performed.append($0) }
        c.faceButton.performClick()
        XCTAssertEqual(performed, [.unified])
    }

    func testPerformingAKind_promotesItOntoTheFaceButton() {
        let c = makeController()
        c.perform = { _ in }
        c.selectKindForTesting(.scrolling)
        XCTAssertEqual(c.faceButton.tooltipText, FloatingCaptureKind.scrolling.title)

        // …and the face button now performs THAT kind.
        var performed: [FloatingCaptureKind] = []
        c.perform = { performed.append($0) }
        c.faceButton.performClick()
        XCTAssertEqual(performed, [.scrolling])
    }

    /// The overflow and the quick pills SPLIT the catalog: every kind is one
    /// click away somewhere, and nothing is listed twice.
    func testOverflowAndQuickPills_splitTheCatalog() {
        let c = makeController()
        let menuTitles = c.overflowMenuForTesting.items.map(\.title)
        let pillTitles = c.quickButtons.map(\.tooltipText)
        for kind in FloatingCaptureKind.allCases {
            let inMenu = menuTitles.contains(kind.title)
            let onPill = pillTitles.contains(kind.title)
            XCTAssertTrue(inMenu || onPill, "\(kind.title) is reachable nowhere")
            XCTAssertFalse(inMenu && onPill, "\(kind.title) is listed twice")
        }
        XCTAssertEqual(pillTitles.count, FloatingCaptureController.quickKinds.count)
    }

    /// Quick pills perform WITHOUT promoting — the face stays the adaptive
    /// last-used slot, so the two never collapse into duplicates.
    func testQuickPill_performsWithoutTakingOverTheFace() {
        let c = makeController()
        var performed: [FloatingCaptureKind] = []
        c.perform = { performed.append($0) }
        let faceBefore = c.faceButton.tooltipText
        c.quickButtons[0].performClick()
        XCTAssertEqual(performed, [FloatingCaptureController.quickKinds[0]])
        XCTAssertEqual(c.faceButton.tooltipText, faceBefore)
    }

    /// While recording, the face is the stop button and the busy gate refuses
    /// parallel starts — the quick pills grey out rather than pretending.
    func testQuickPills_disableWhileRecording() {
        let c = makeController()
        c.setRecording(true, paused: false)
        XCTAssertTrue(c.quickButtons.allSatisfy { !$0.isEnabled })
        c.setRecording(false, paused: false)
        XCTAssertTrue(c.quickButtons.allSatisfy { $0.isEnabled })
    }

    func testRestoreButton_opensTheEditor() {
        let c = makeController()
        var opened = 0
        c.openEditor = { opened += 1 }
        c.restoreButtonForTesting.performClick()
        XCTAssertEqual(opened, 1)
    }

    func testCaptureLanded_updatesTheCountLabel() {
        let c = makeController()
        c.captureLanded()
        c.captureLanded()
        XCTAssertEqual(c.countLabel.stringValue, "2")
    }

    func testEditorWasOpened_resetsTheCountLabel() {
        let c = makeController()
        c.captureLanded()
        c.editorWasOpened()
        XCTAssertEqual(c.countLabel.stringValue, "0")
    }

    // MARK: Recording state

    func testWhileRecording_theFaceButtonBecomesStop() {
        let c = makeController()
        c.setRecording(true, paused: false)
        XCTAssertEqual(c.faceButton.tooltipText, "Stop Recording")
    }

    func testWhileRecording_theFaceButtonStopsRatherThanCaptures() {
        let c = makeController()
        var performed: [FloatingCaptureKind] = []
        var stopped = 0
        c.perform = { performed.append($0) }
        c.stopRecording = { stopped += 1 }
        c.setRecording(true, paused: false)
        c.faceButton.performClick()
        XCTAssertEqual(stopped, 1)
        XCTAssertTrue(performed.isEmpty)
    }

    func testWhileRecording_overflowCollapsesToRecordingControls() {
        let c = makeController()
        c.setRecording(true, paused: false)
        XCTAssertEqual(c.overflowMenuForTesting.items.map(\.title),
                       ["Pause Recording", "Stop Recording"])
    }

    func testWhilePaused_theOverflowOffersResume() {
        let c = makeController()
        c.setRecording(true, paused: true)
        XCTAssertEqual(c.overflowMenuForTesting.items.first?.title, "Resume Recording")
    }

    func testAfterRecordingStops_theFaceButtonComesBack() {
        let c = makeController()
        c.setRecording(true, paused: false)
        c.setRecording(false, paused: false)
        XCTAssertEqual(c.faceButton.tooltipText, FloatingCaptureKind.unified.title)
    }

    // MARK: Fade at rest

    /// Hover-driven, NOT focus-driven: the panel never becomes key, so a
    /// focus-based fade would leave it dim forever.
    func testRestingOpacity_dimsWhenNotHoveredAndClearsOnHover() {
        let c = makeController()
        c.applyRestingOpacity(hovering: false)
        XCTAssertEqual(c.panelAlphaForTesting,
                       FloatingCaptureController.restingOpacity, accuracy: 0.001)
        c.applyRestingOpacity(hovering: true)
        XCTAssertEqual(c.panelAlphaForTesting, 1, accuracy: 0.001)
    }

    /// A fully transparent window still takes clicks, and an invisible click
    /// target reads as broken — so the fade has a floor.
    func testRestingOpacity_neverFallsBelowUsable() {
        XCTAssertGreaterThanOrEqual(FloatingCaptureController.restingOpacity, 0.4)
    }

    // MARK: Drag settle

    func testSettleAfterDrag_snapsToTheNearestCorner() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 20, y: visible.minY + 22,
                                    width: 120, height: 70))
        c.settleAfterDrag()
        XCTAssertEqual(c.panelFrameForTesting.minX,
                       visible.minX + FloatingCaptureGeometry.margin, accuracy: 1)
        XCTAssertEqual(c.panelFrameForTesting.minY,
                       visible.minY + FloatingCaptureGeometry.margin, accuracy: 1)
    }

    // MARK: Locked

    /// Every button on the panel refuses while the app is locked, so a panel of
    /// dead controls sitting over the lock screen is worse than no panel.
    func testShow_refusesWhileLocked() {
        let c = makeController()
        c.isLocked = { true }
        c.show()
        XCTAssertFalse(c.isVisible)
    }

    /// `show()` is the choke point for every route — toolbar, menu, launch
    /// restore, unlock — so unlocking is the only thing that lets it back.
    func testShow_worksAgainOnceUnlocked() {
        let c = makeController()
        var locked = true
        c.isLocked = { locked }
        c.show()
        XCTAssertFalse(c.isVisible)

        locked = false
        c.show()
        XCTAssertTrue(c.isVisible)
    }

    func testLock_takesTheOpenPanelDownAndUnlockBringsItBack() {
        let c = makeController()
        var locked = false
        c.isLocked = { locked }
        c.show()
        XCTAssertTrue(c.isVisible)

        locked = true
        c.hideForLock()
        XCTAssertFalse(c.isVisible)

        locked = false
        c.restoreAfterUnlock()
        XCTAssertTrue(c.isVisible)
    }

    /// Unlocking must not summon a panel the user had closed themselves.
    func testUnlock_doesNotOpenAPanelThatWasAlreadyClosed() {
        let c = makeController()
        c.hideForLock()          // locked while the panel was not showing
        c.restoreAfterUnlock()
        XCTAssertFalse(c.isVisible)
    }

    /// Launching into a locked session must not cost the panel for the rest of
    /// the session: `show()` refuses, but the unlock puts it back.
    func testPendingUnlockRestore_survivesALaunchIntoALockedSession() {
        let c = makeController()
        var locked = true
        c.isLocked = { locked }
        c.show()
        XCTAssertFalse(c.isVisible)
        c.markPendingUnlockRestore()

        locked = false
        c.restoreAfterUnlock()
        XCTAssertTrue(c.isVisible)
    }

    // MARK: Snap guides

    /// Near a corner, both guides show — a vertical line on the side it will
    /// snap to and a horizontal one on the top or bottom.
    func testSnapGuides_nearACorner_showBothLines() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 20, y: visible.minY + 22,
                                    width: 120, height: 70))
        c.updateSnapGuides()

        XCTAssertTrue(c.snapGuidesForTesting.isVisible)
        XCTAssertNotNil(c.snapGuidesForTesting.verticalXForTesting)
        XCTAssertNotNil(c.snapGuidesForTesting.horizontalYForTesting)
    }

    /// Near one edge only, only that edge's line shows.
    func testSnapGuides_nearOneEdge_showOneLine() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 20, y: visible.midY,
                                    width: 120, height: 70))
        c.updateSnapGuides()

        XCTAssertTrue(c.snapGuidesForTesting.isVisible)
        XCTAssertNotNil(c.snapGuidesForTesting.verticalXForTesting)
        XCTAssertNil(c.snapGuidesForTesting.horizontalYForTesting)
    }

    /// Far from every edge, no guides at all — an always-on line would be
    /// noise, and would promise a snap that isn't going to happen.
    func testSnapGuides_awayFromEveryEdge_showNothing() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY, width: 120, height: 70))
        c.updateSnapGuides()
        XCTAssertFalse(c.snapGuidesForTesting.isVisible)
    }

    /// The guides describe a drag in progress; releasing must clear them.
    func testSnapGuides_areClearedWhenTheDragEnds() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 20, y: visible.minY + 22,
                                    width: 120, height: 70))
        c.updateSnapGuides()
        XCTAssertTrue(c.snapGuidesForTesting.isVisible)

        c.settleAfterDrag()
        XCTAssertFalse(c.snapGuidesForTesting.isVisible)
    }

    /// A guide left on screen during a capture would be captured.
    func testSnapGuides_areClearedWhenThePanelHidesForACapture() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 20, y: visible.minY + 22,
                                    width: 120, height: 70))
        c.updateSnapGuides()
        c.hideForCapture()
        XCTAssertFalse(c.snapGuidesForTesting.isVisible)
    }

    // MARK: Recent-capture strip

    /// The strip is a pure projection of the library's newest captures —
    /// whatever the provider lists, in its order. Nothing appends to it.
    func testStrip_mirrorsTheLibrarysNewestCaptures() async {
        let c = makeController()
        c.recentProvider = { [stripItem("/tmp/b.seal"), stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        XCTAssertEqual(c.stripURLsForTesting,
                       [URL(fileURLWithPath: "/tmp/b.seal"), URL(fileURLWithPath: "/tmp/a.seal")])
        XCTAssertEqual(c.thumbnailCountForTesting, 2)
    }

    /// Exactly the strip's leftmost three — a fixed window onto the library's
    /// newest, not a growing list and not "as many as fit".
    func testStrip_showsAtMostThreeTiles() async {
        let c = makeController()
        c.recentProvider = { (0..<8).map { stripItem("/tmp/\($0).seal") } }
        await c.refreshStripForTesting()
        XCTAssertEqual(c.thumbnailCountForTesting,
                       FloatingCaptureController.shownTileCount)
        XCTAssertEqual(c.stripURLsForTesting.first, URL(fileURLWithPath: "/tmp/0.seal"))
    }

    /// Deletions reach the strip the same way additions do: the library
    /// changed, so the projection is refetched — a deleted capture's tile is
    /// gone because the library no longer lists it. No per-event bookkeeping.
    func testStrip_dropsItemsTheLibraryNoLongerLists() async {
        let c = makeController()
        c.recentProvider = { [stripItem("/tmp/a.seal"), stripItem("/tmp/b.seal")] }
        await c.refreshStripForTesting()
        XCTAssertEqual(c.thumbnailCountForTesting, 2)

        // "a" deleted — from the editor strip, the Library or Finder alike.
        c.recentProvider = { [stripItem("/tmp/b.seal")] }
        await c.refreshStripForTesting()
        XCTAssertEqual(c.stripURLsForTesting, [URL(fileURLWithPath: "/tmp/b.seal")])
        XCTAssertEqual(c.thumbnailCountForTesting, 1)
    }

    /// Videos ride the same strip, flagged from the index's captureKind — a
    /// video `.seal` looks identical to an image `.seal` on disk — and badged
    /// with a play glyph so they read as videos at 64pt.
    func testStrip_videoTileGetsAPlayBadge() async {
        let c = makeController()
        c.recentProvider = { [stripItem("/tmp/clip.seal", video: true),
                              stripItem("/tmp/still.seal")] }
        await c.refreshStripForTesting()
        let tiles = c.thumbnailTilesForTesting
        XCTAssertEqual(tiles.count, 2)
        XCTAssertTrue(tiles[0].isVideo)
        XCTAssertTrue(tiles[0].playBadgeVisibleForTesting)
        XCTAssertFalse(tiles[1].isVideo)
        XCTAssertFalse(tiles[1].playBadgeVisibleForTesting)
    }

    /// Before the first capture of a run the strip says so, rather than being
    /// a blank gap the user has to interpret.
    func testStrip_showsAPlaceholderBeforeTheFirstCapture() {
        let c = makeController()
        XCTAssertTrue(c.stripPlaceholderVisibleForTesting)
        XCTAssertEqual(c.thumbnailCountForTesting, 0)
    }

    func testStrip_placeholderGivesWayToTheFirstThumbnail() async {
        let c = makeController()
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        XCTAssertFalse(c.stripPlaceholderVisibleForTesting)
        XCTAssertEqual(c.thumbnailCountForTesting, 1)
    }

    /// Compact hides the strip entirely, placeholder included.
    func testStrip_compactShowsNoPlaceholder() {
        let c = makeController()
        c.size = .compact
        XCTAssertFalse(c.stripPlaceholderVisibleForTesting)
    }

    /// The strip mirrors the library's latest captures — opening the editor
    /// must NOT clear it.
    func testEditorWasOpened_leavesTheStripAlone() async {
        let c = makeController()
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        c.captureLanded()
        c.editorWasOpened()
        XCTAssertEqual(c.countLabel.stringValue, "0", "the (hidden) count still resets")
        XCTAssertEqual(c.stripURLsForTesting, [URL(fileURLWithPath: "/tmp/a.seal")])
        XCTAssertEqual(c.thumbnailCountForTesting, 1)
    }

    /// Opening the panel refreshes the projection, so it appears already
    /// showing recent work — no capture needed first.
    func testShow_populatesTheStripFromTheLibrary() async {
        let c = makeController()
        c.recentProvider = { [stripItem("/tmp/lib1.seal"), stripItem("/tmp/lib2.seal")] }
        c.show()
        await c.refreshStripForTesting()
        XCTAssertEqual(c.stripURLsForTesting,
                       [URL(fileURLWithPath: "/tmp/lib1.seal"),
                        URL(fileURLWithPath: "/tmp/lib2.seal")])
        XCTAssertEqual(c.thumbnailCountForTesting, 2)
    }

    /// A capture from ANY surface — editor window, hotkey, menu bar, the panel
    /// itself — posts `.captureFilesImported`; the panel refetches on it.
    func testCaptureNotification_triggersARefetch() async {
        let c = makeController()
        let refetched = expectation(description: "provider consulted")
        c.recentProvider = { refetched.fulfill(); return [] }
        NotificationCenter.default.post(name: .captureFilesImported,
                                        object: [URL(fileURLWithPath: "/tmp/x.seal")],
                                        userInfo: ["kind": "capture"])
        await fulfillment(of: [refetched], timeout: 2)
    }

    /// A background reconcile that changed the index reaches the strip too —
    /// the signal reconcile-driven deletions and additions arrive on.
    func testIndexChange_triggersARefetch() async {
        let c = makeController()
        let refetched = expectation(description: "provider consulted")
        c.recentProvider = { refetched.fulfill(); return [] }
        NotificationCenter.default.post(name: .libraryIndexDidChange, object: nil)
        await fulfillment(of: [refetched], timeout: 2)
    }

    /// Scoped like the editor strip: a reconcile of some OTHER folder (the
    /// trash, an old save location) must not churn this strip.
    func testIndexChangeForAnotherFolder_isIgnored() async {
        let c = makeController()
        c.saveFolderProvider = { URL(fileURLWithPath: "/tmp/watched") }
        let refetched = expectation(description: "provider consulted")
        refetched.isInverted = true
        c.recentProvider = { refetched.fulfill(); return [] }
        NotificationCenter.default.post(name: .libraryIndexDidChange,
                                        object: URL(fileURLWithPath: "/tmp/other"))
        await fulfillment(of: [refetched], timeout: 0.3)
    }

    /// Three tiles in strip and standard; compact hides the row entirely.
    func testStrip_showsThreeTilesAndCompactHidesThem() async {
        let c = makeController()
        c.recentProvider = { (0..<8).map { stripItem("/tmp/\($0).seal") } }
        await c.refreshStripForTesting()
        c.size = .strip
        XCTAssertEqual(c.thumbnailCountForTesting, 3)
        c.size = .standard
        XCTAssertEqual(c.thumbnailCountForTesting, 3)
        c.size = .compact
        XCTAssertEqual(c.thumbnailCountForTesting, 0)
    }

    /// The panel has to grow to fit the strip — a fixed height would clip the
    /// thumbnails the moment the first capture landed.
    func testPanel_growsWhenTheFirstThumbnailArrives() async {
        let c = makeController()
        c.show()
        let before = c.panelFrameForTesting.height
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        XCTAssertGreaterThan(c.panelFrameForTesting.height, before)
    }

    /// Growing downward would make the panel appear to jump. It grows from a
    /// fixed top edge instead.
    func testPanel_growsFromAFixedTopEdge() async {
        let c = makeController()
        c.show()
        let topBefore = c.panelFrameForTesting.maxY
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        XCTAssertEqual(c.panelFrameForTesting.maxY, topBefore, accuracy: 0.5)
    }

    // MARK: Following the pointer across displays

    /// Only a panel parked in a full corner follows the pointer. One parked
    /// against a single edge — or left free-floating — stays where the user put
    /// it, and a call with no snap must be inert.
    func testFollowPointer_doesNothingWhenNotCornered() {
        let c = makeController()
        c.show()
        c.setFrameForTesting(NSRect(x: 400, y: 380, width: 120, height: 70))
        let before = c.panelFrameForTesting
        c.followPointerIfNeeded(pointer: NSPoint(x: 9_000, y: 9_000), animated: false)
        XCTAssertEqual(c.panelFrameForTesting, before)
    }

    /// A pointer on the panel's own screen changes nothing — the follow only
    /// fires on a display change, so it stays cheap on every mouse move.
    func testFollowPointer_onTheSameDisplay_doesNotMoveThePanel() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 20, y: visible.minY + 22,
                                    width: 120, height: 70))
        c.settleAfterDrag()
        let settled = c.panelFrameForTesting
        c.followPointerIfNeeded(pointer: NSPoint(x: visible.midX, y: visible.midY),
                                animated: false)
        XCTAssertEqual(c.panelFrameForTesting, settled)
    }

    /// Regression: the slide to another display parks the panel OUTSIDE the
    /// target screen before animating in, and `panel.screen` is nil there. A
    /// follow that compared against `panel.screen` therefore decided on every
    /// poll that the panel still hadn't arrived, restarted the slide from
    /// off-screen, and the panel was never seen again. The follow now compares
    /// against the display it placed the panel on, so a repeat call is inert.
    func testFollowPointer_repeatedCallsForTheSamePointerAreInert() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 20, y: visible.minY + 22,
                                    width: 120, height: 70))
        c.settleAfterDrag()
        let settled = c.panelFrameForTesting

        let pointer = NSPoint(x: visible.midX, y: visible.midY)
        for _ in 0..<5 {
            c.followPointerIfNeeded(pointer: pointer, animated: false)
        }
        XCTAssertEqual(c.panelFrameForTesting, settled)
    }

    /// Following was unreachable on a fresh panel: only `settleAfterDrag` set
    /// the corner, so a panel that had never been dragged — every panel the
    /// first time it appears — counted as free-floating and stayed put. It now
    /// works out where it is when it appears.
    func testShow_recognisesTheCornerItAppearsIn() {
        let c = makeController()
        c.show()
        XCTAssertTrue(c.isCorneredForTesting,
                      "a panel placed in its default corner must know it is in one")
    }

    /// A visible panel outside every screen is unreachable — no pointer can
    /// hover it, no click can drag it back. It must recover itself.
    func testRecoverIfStranded_bringsAnOffScreenPanelBack() throws {
        let c = makeController()
        c.show()
        c.setFrameForTesting(NSRect(x: 60_000, y: 60_000, width: 120, height: 70))
        XCTAssertFalse(NSScreen.screens.contains {
            $0.visibleFrame.intersects(c.panelFrameForTesting)
        }, "precondition: the panel starts stranded")

        c.recoverIfStranded()
        XCTAssertTrue(NSScreen.screens.contains {
            $0.visibleFrame.intersects(c.panelFrameForTesting)
        }, "a stranded panel must come back onto a screen")
    }

    /// Recovery must not fidget with a panel that is perfectly fine.
    func testRecoverIfStranded_leavesAnOnScreenPanelAlone() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY, width: 120, height: 70))
        let before = c.panelFrameForTesting
        c.recoverIfStranded()
        XCTAssertEqual(c.panelFrameForTesting, before)
    }

    /// Unplugging a monitor is the one way a DOCKED line can be stranded: the
    /// edge it hugs stops existing. It was excluded from recovery on the
    /// reasoning that a line always hugs a real edge — true until the display
    /// goes away, and then there is no chevron to click and no panel to drag.
    func testRecoverIfStranded_bringsAStrandedDockedLineBack() throws {
        let c = try dockedController()
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: -60_000,
                                    width: 18, height: 64))
        XCTAssertFalse(NSScreen.screens.contains {
            $0.frame.intersects(c.panelFrameForTesting)
        }, "precondition: the line starts on a display that no longer exists")

        c.recoverIfStranded()
        XCTAssertTrue(NSScreen.screens.contains {
            $0.frame.intersects(c.panelFrameForTesting)
        }, "the line must come back onto a live screen")
        XCTAssertTrue(c.isDockedForTesting, "…still docked, on the same edge")
    }

    /// A docked line sitting on a screen that still exists is left alone.
    func testRecoverIfStranded_leavesALiveDockedLineAlone() throws {
        let c = try dockedController()
        let before = c.panelFrameForTesting
        c.recoverIfStranded()
        XCTAssertEqual(c.panelFrameForTesting, before)
    }

    /// Showing the panel is the user asking to SEE it, so it is the last
    /// chance to catch a docked line left on a display that has gone away.
    /// This path used to order the line front at its dead coordinates and
    /// return, so hiding and re-showing could not rescue it.
    func testShow_rescuesAStrandedDockedLine() throws {
        let c = try dockedController()
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: -60_000,
                                    width: 18, height: 64))
        c.show()
        XCTAssertTrue(NSScreen.screens.contains {
            $0.frame.intersects(c.panelFrameForTesting)
        }, "showing a stranded line must bring it back")
    }

    // MARK: Reset Position

    /// The escape hatch, for a panel in a state the user cannot click their
    /// way out of: undocked, in the default corner, on a screen they have.
    func testResetPosition_undocksAndCentresOnScreen() throws {
        let c = try dockedController()
        XCTAssertTrue(c.isDockedForTesting, "precondition: docked")

        c.resetPosition()
        XCTAssertFalse(c.isDockedForTesting, "no longer a line")
        let frame = c.panelFrameForTesting
        let screen = try XCTUnwrap(NSScreen.screens.first {
            $0.visibleFrame.intersects(frame)
        }, "on a screen that exists")
        // Centre, not a corner: a corner is a plausible place for a panel to
        // be hiding, which defeats the point of a rescue.
        XCTAssertEqual(frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, screen.visibleFrame.midY, accuracy: 1)
        XCTAssertEqual(frame.size, NSSize(width: 240, height: 132),
                       "restored at its pre-dock size, not the line's 18pt")
    }

    /// Reset works on a panel that is merely lost rather than docked.
    func testResetPosition_rescuesAStrandedUndockedPanel() throws {
        let c = makeController()
        c.show()
        c.setFrameForTesting(NSRect(x: 60_000, y: 60_000, width: 120, height: 70))
        c.resetPosition()
        XCTAssertTrue(NSScreen.screens.contains {
            $0.visibleFrame.intersects(c.panelFrameForTesting)
        })
    }

    /// …and it forgets the docks, or the next launch restores the very state
    /// the user just escaped from.
    func testResetPosition_forgetsRememberedDocks() throws {
        let c = try dockedController()
        XCTAssertNotNil(suite.dictionary(forKey: "FloatingCaptureWindowDock"),
                        "precondition: docking remembered something")
        c.resetPosition()
        XCTAssertNil(suite.dictionary(forKey: "FloatingCaptureWindowDock"),
                     "every display's dock is forgotten")
    }

    /// The display count decides whether the pointer poll runs at all, so a
    /// desk change makes the last evaluation stale — and a stranded panel is
    /// usually in exactly the state where the poll is NOT armed, which is why
    /// this notification has to do the rescuing itself.
    func testScreenSetupChanged_rescuesAStrandedPanel() throws {
        let c = makeController()
        c.show()
        c.setFrameForTesting(NSRect(x: 60_000, y: 60_000, width: 120, height: 70))
        c.screenSetupChanged()
        XCTAssertTrue(NSScreen.screens.contains {
            $0.visibleFrame.intersects(c.panelFrameForTesting)
        })
    }



    // MARK: Edge docking

    /// Shoving the panel well past a screen edge collapses it to a thin line
    /// there; releasing it just short of the trigger snaps back as always.
    func testShovePastEdge_docksToALine() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 90))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting)
        XCTAssertEqual(c.panelFrameForTesting.width,
                       FloatingCaptureGeometry.dockedLineThickness, accuracy: 0.5)
        XCTAssertEqual(c.panelFrameForTesting.minX, leftmostVisibleFrame.minX, accuracy: 0.5)
    }

    func testSmallOvershoot_snapsBackInsteadOfDocking() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX - 10, y: visible.midY,
                                    width: 240, height: 90))
        c.settleAfterDrag()
        XCTAssertFalse(c.isDockedForTesting)
        XCTAssertEqual(c.panelFrameForTesting.minX,
                       visible.minX + FloatingCaptureGeometry.margin, accuracy: 1)
    }

    /// A click on the line restores the panel beside its edge at full size.
    func testRestoreFromDock_bringsThePanelBack() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let sizeBefore = c.panelFrameForTesting.size
        c.setFrameForTesting(NSRect(origin: CGPoint(x: pastLeftEdgeOfEverything, y: visible.midY),
                                    size: sizeBefore))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting)

        c.restoreFromDock()
        XCTAssertFalse(c.isDockedForTesting)
        XCTAssertEqual(c.panelFrameForTesting.width, sizeBefore.width, accuracy: 1)
        XCTAssertEqual(c.panelFrameForTesting.minX,
                       leftmostVisibleFrame.minX + FloatingCaptureGeometry.margin, accuracy: 1,
                       "restored beside the edge it was docked to")
    }

    /// The docked line carries an arrow pointing back INTO the screen.
    func testDockedLine_showsTheRestoreChevron() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 90))
        c.settleAfterDrag()
        XCTAssertEqual(c.dockedChevronSymbolForTesting, "chevron.right",
                       "docked on the LEFT edge → arrow points right, back in")
    }

    /// A line-drag released NEAR an edge re-parks the line there rather than
    /// restoring the panel — restore-on-release made every slide along the
    /// edges an accidental restore. A click still brings the panel back.
    func testDraggingTheDockedLine_reParksItInsteadOfRestoring() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 90))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting)
        let lineSize = c.panelFrameForTesting.size

        // Slide the line along, staying close to the bottom edge, and release.
        // The line is 18×64 here (docked left), so its CENTER — what
        // lineRelease measures — sits 32pt above the drop origin.
        c.setFrameForTesting(NSRect(origin: CGPoint(x: visible.midX,
                                                    y: visible.minY + 10),
                                    size: lineSize))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting, "a dragged line stays a line")
        XCTAssertEqual(c.panelFrameForTesting.size.height,
                       FloatingCaptureGeometry.dockedLineThickness,
                       "re-parked on the BOTTOM edge, the nearest one")

        // The click path still restores.
        c.restoreFromDock()
        XCTAssertFalse(c.isDockedForTesting)
    }

    /// Pulling the line clearly OFF its edge is the drag that DOES restore —
    /// distinct from sliding it near the edges, which only re-parks.
    func testDraggingTheLineOffTheEdge_undocksThePanel() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let sizeBefore = c.panelFrameForTesting.size
        c.setFrameForTesting(NSRect(origin: CGPoint(x: pastLeftEdgeOfEverything,
                                                    y: visible.midY),
                                    size: sizeBefore))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting)
        let lineSize = c.panelFrameForTesting.size

        // Pull the line into the middle of the screen and release.
        c.setFrameForTesting(NSRect(origin: CGPoint(x: visible.midX,
                                                    y: visible.midY),
                                    size: lineSize))
        c.settleAfterDrag()
        XCTAssertFalse(c.isDockedForTesting, "pulled off the edge → undocked")
        XCTAssertEqual(c.panelFrameForTesting.size, sizeBefore,
                       "the full panel is back at its pre-dock size")
    }

    /// A capture landing while docked must re-render the hidden strip without
    /// resizing the line back into a panel.
    func testCaptureWhileDocked_leavesTheLineAlone() async throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 90))
        c.settleAfterDrag()
        let lineFrame = c.panelFrameForTesting

        c.recentProvider = { [stripItem("/tmp/docked.seal")] }
        await c.refreshStripForTesting()
        XCTAssertTrue(c.isDockedForTesting)
        XCTAssertEqual(c.panelFrameForTesting, lineFrame,
                       "a landed capture must not resize the docked line")
    }

    // MARK: Hide during capture

    func testHideForCapture_thenRestore_returnsTheVisiblePanel() {
        let c = makeController()
        c.show()
        c.hideForCapture()
        XCTAssertFalse(c.isVisible)
        c.restoreAfterCapture()
        XCTAssertTrue(c.isVisible)
    }

    /// If the panel was closed before the capture, a capture from some other
    /// surface must not be what opens it.
    func testRestoreAfterCapture_doesNotOpenAPanelThatWasClosed() {
        let c = makeController()
        c.hideForCapture()
        c.restoreAfterCapture()
        XCTAssertFalse(c.isVisible)
    }

    /// Recordings never hide the panel, so their "capture ended" must not
    /// consult the flag left by the last still capture — which could re-show a
    /// panel the user closed in between.
    func testRestoreAfterCapture_withoutAHide_isInert() {
        let c = makeController()
        c.show()
        c.hideForCapture()
        c.restoreAfterCapture()
        XCTAssertTrue(c.isVisible)

        // The user closes it; a later "capture ended" must leave it closed.
        c.hide()
        c.restoreAfterCapture()
        XCTAssertFalse(c.isVisible)
    }

    func testPanelControls_trackTooltipsWhileTheAppIsInactive() {
        let c = makeController()
        XCTAssertTrue(c.faceButton.tracksWhileAppInactive)
        XCTAssertTrue(c.restoreButtonForTesting.tracksWhileAppInactive)
    }

    // MARK: Chrome row

    func testChrome_isHiddenAtRestAndShownOnHover() {
        let c = makeController()
        c.show()
        XCTAssertEqual(c.chromeAlphaForTesting, 0, accuracy: 0.001,
                       "the resting panel must look exactly as it did before")
        c.setHoveringForTesting(true)
        XCTAssertEqual(c.chromeAlphaForTesting, 1, accuracy: 0.001)
        c.setHoveringForTesting(false)
        XCTAssertEqual(c.chromeAlphaForTesting, 0, accuracy: 0.001)
    }

    /// The row keeps its height whether or not the glyphs show, so nothing
    /// reflows under the pointer as they fade in.
    func testChrome_reservesItsHeightWhileHidden() {
        let c = makeController()
        c.show()
        let resting = c.panelFrameForTesting.height
        c.setHoveringForTesting(true)
        XCTAssertEqual(c.panelFrameForTesting.height, resting, accuracy: 0.001)
    }

    func testCloseButton_requestsTheSameCloseAsTheEditorToggle() {
        let c = makeController()
        var closes = 0
        c.onCloseRequested = { closes += 1 }
        c.closeButton.performClick()
        XCTAssertEqual(closes, 1)
    }

    func testPinButton_glyphAndTooltipFollowTheState() {
        let c = makeController()
        c.pinState = .pinned
        XCTAssertEqual(c.pinButton.tooltipText, FloatingPinState.pinned.tooltip)
        c.pinState = .unpinned
        XCTAssertEqual(c.pinButton.tooltipText, FloatingPinState.unpinned.tooltip)
    }

    /// The chrome row must not widen the panel past its (deliberately
    /// widened) baseline — same bound as `testPanel_holdsItsWidenedBaseline`.
    func testPanel_chromeDoesNotWidenThePanel() {
        let c = makeController()
        c.show()
        XCTAssertLessThanOrEqual(c.panelFrameForTesting.width, 320)
    }

    // MARK: Pin behaviour

    func testPinned_panelFloatsAboveOtherWindows() {
        let c = makeController()
        c.show()
        c.pinState = .pinned
        XCTAssertEqual(c.panelLevelForTesting, .floating)
    }

    func testUnpinned_panelDropsToNormalSoOtherWindowsCoverIt() {
        let c = makeController()
        c.show()
        c.pinState = .unpinned
        XCTAssertEqual(c.panelLevelForTesting, .normal)
    }

    func testPinStateSurvivesAReopen() {
        let c = makeController()
        c.show()
        c.pinState = .unpinned
        c.hide()
        c.show()
        XCTAssertEqual(c.panelLevelForTesting, .normal,
                       "reopening must not silently re-pin the panel")
    }

    /// The panel never becomes key, so clicking its pin button changes no key
    /// state and `didBecomeKey` will not fire. If unpinning did not ask for the
    /// ride itself, a panel unpinned while the editor is already key and
    /// overlapping it would simply vanish with no way back.
    func testUnpinning_immediatelyAsksToRideTheEditor() {
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let c = makeController()
        c.editorWindow = { editor }
        c.show()
        XCTAssertEqual(c.followAttemptsForTesting, 0)
        c.pinState = .unpinned
        XCTAssertEqual(c.followAttemptsForTesting, 1)
    }

    /// Re-pinning needs no ride — the panel is above everything again — so the
    /// follow must not fire for it.
    func testRepinning_doesNotAskToRideTheEditor() {
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let c = makeController()
        c.editorWindow = { editor }
        c.show()
        c.pinState = .unpinned
        let after = c.followAttemptsForTesting
        c.pinState = .pinned
        XCTAssertEqual(c.followAttemptsForTesting, after)
    }

    /// The ride cannot take while the editor is parked at `.floating` by
    /// `raiseAboveOtherApps` — which is precisely when `didBecomeKey` fires —
    /// so the same follow has to run again once the level settles.
    func testFollowingTheEditor_reportsWhetherTheOrderingCouldTake() {
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let c = makeController()
        c.show()
        c.pinState = .unpinned

        editor.level = .floating
        XCTAssertFalse(c.followEditorIfUnpinned(editor),
                       "ordering above a higher-level window is a silent no-op")
        editor.level = .normal
        XCTAssertTrue(c.followEditorIfUnpinned(editor))
    }

    /// A pinned panel is above the editor already and must not be re-ordered.
    func testFollowingTheEditor_doesNothingWhilePinned() {
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let c = makeController()
        c.show()
        c.pinState = .pinned
        XCTAssertFalse(c.followEditorIfUnpinned(editor))
        XCTAssertEqual(c.followAttemptsForTesting, 0)
    }

    // MARK: Drag lifelines

    /// The promise delegate AppKit holds weakly must outlive the tile it was
    /// dragged from: every landed capture and every editor open rebuilds the
    /// whole thumbnail row, either of which can happen while the drop is still
    /// unfulfilled. A tile-owned retainer dies there and the drop produces
    /// nothing at all.
    func testDragLifeline_survivesAThumbnailRowRebuild() async {
        final class Lifeline {}
        let c = makeController()
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()

        var lifeline: Lifeline? = Lifeline()
        // Declared then assigned, not initialised in place: `weak` cannot be
        // `let`, so an initialised-and-never-reassigned weak local trips
        // "never mutated — consider changing to let", which is unfollowable
        // and fails the build under warnings-as-errors.
        weak var observed: Lifeline?
        observed = lifeline
        c.retainDragLifeline(lifeline!)
        lifeline = nil

        c.recentProvider = { [stripItem("/tmp/b.seal"), stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        c.editorWasOpened()
        XCTAssertNotNil(observed,
                        "a drag in flight must survive the tile being recreated")
    }

    /// Each tile hands its promise delegate to the controller rather than
    /// keeping it — the wiring that makes the test above mean anything.
    func testTilesHandTheirDragLifelinesToTheController() async {
        final class Lifeline {}
        let c = makeController()
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        guard let tile = c.thumbnailTilesForTesting.first else {
            return XCTFail("a listed capture must render a tile")
        }
        tile.retainDragLifeline?(Lifeline())
        XCTAssertEqual(c.dragRetainerCountForTesting, 1)
    }

    /// Bounded, so a long session cannot accumulate export state forever.
    func testDragLifelines_areBounded() {
        final class Lifeline {}
        let c = makeController()
        for _ in 0..<12 { c.retainDragLifeline(Lifeline()) }
        XCTAssertLessThanOrEqual(c.dragRetainerCountForTesting, 4)
    }

    func testPinButtonGlyph_tracksTheState() {
        let c = makeController()
        c.pinState = .unpinned
        XCTAssertEqual(c.pinButton.tooltipText, FloatingPinState.unpinned.tooltip)
        c.pinButton.performClick()
        XCTAssertEqual(c.pinState, .pinned)
        XCTAssertEqual(c.pinButton.tooltipText, FloatingPinState.pinned.tooltip)
    }

    // MARK: Docked state survives a restart

    /// A panel left docked comes back docked. Reported from the field: it
    /// reopened as a full panel at its pre-dock position, so tucking it away
    /// lasted only until the next launch.
    ///
    func testDockedPanel_comesBackDockedAfterARestart() throws {
        let first = makeController()
        first.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        first.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                        width: 240, height: 132))
        first.settleAfterDrag()
        XCTAssertTrue(first.isDockedForTesting, "precondition: docked")
        let lineFrame = first.panelFrameForTesting
        first.hide()

        // A fresh controller reading the same defaults is what a relaunch is.
        let relaunched = makeController()
        relaunched.show()
        XCTAssertTrue(relaunched.isDockedForTesting,
                      "a docked panel must not reopen as a full panel")
        XCTAssertEqual(relaunched.panelFrameForTesting, lineFrame,
                       "and on the same edge, in the same place")
    }

    /// Undocking is remembered too — otherwise the next launch would tuck it
    /// away again after the user deliberately brought it back.
    func testUndockedPanel_staysUndockedAfterARestart() throws {
        let first = makeController()
        first.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        first.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                        width: 240, height: 132))
        first.settleAfterDrag()
        XCTAssertTrue(first.isDockedForTesting)
        first.restoreFromDock()
        XCTAssertFalse(first.isDockedForTesting)
        first.hide()

        let relaunched = makeController()
        relaunched.show()
        XCTAssertFalse(relaunched.isDockedForTesting)
    }

    // MARK: Auto-dock

    /// Auto-docking SLIDES (same motion as following the pointer to another
    /// display), so the line's frame lands at the end of the animation and
    /// `isSliding` gates the next dock until then.
    /// Leaving the panel only ARMS the countdown now; this completes it with
    /// the pointer well clear, which is what the timer checks.
    private func leaveAndSettle(_ c: FloatingCaptureController) {
        c.setHoveringForTesting(false)
        c.autoDockTimerFired(pointer: NSPoint(x: -10_000, y: -10_000))
    }

    /// Wait for the slide to actually finish rather than for a duration:
    /// under load a fixed sleep expires mid-animation, `isSliding` is still
    /// true, and the next auto-dock is refused — which failed the assertion
    /// AFTER it, intermittently and confusingly.
    private func awaitSlide(_ c: FloatingCaptureController? = nil) async {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if let c, !c.isSlidingForTesting { return }
        } while Date() < deadline && c != nil
        if c == nil {
            try? await Task.sleep(nanoseconds: UInt64(
                (FloatingCaptureController.slideDuration + 0.15) * 1_000_000_000))
        }
    }

    func testAutoDock_isOffByDefault() {
        XCTAssertFalse(makeController().autoDockEnabled,
                       "auto-hiding is too strong to inflict on someone who never asked")
    }

    /// The feature itself: with it on, the pointer leaving the panel tucks it
    /// against the nearest edge.
    func testAutoDock_docksWhenThePointerLeaves() throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        // Well inside the screen, nearer the left edge than any other.
        c.setFrameForTesting(NSRect(x: visible.minX + 30, y: visible.midY,
                                    width: 240, height: 132))
        c.setHoveringForTesting(true)
        XCTAssertFalse(c.isDockedForTesting)

        leaveAndSettle(c)
        XCTAssertTrue(c.isDockedForTesting, "leaving the panel should tuck it away")
        XCTAssertEqual(c.dockedChevronSymbolForTesting, "chevron.right",
                       "docked on the LEFT edge it was nearest to")
    }

    func testAutoDockOff_leavingThePanelDoesNothing() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 30, y: visible.midY,
                                    width: 240, height: 132))
        c.setHoveringForTesting(true)
        leaveAndSettle(c)
        XCTAssertFalse(c.isDockedForTesting)
    }

    /// Restoring grows the panel out from under the cursor, so the very next
    /// exit event must NOT re-dock it — otherwise the panel could never be
    /// used while auto-dock is on.
    func testAfterRestoring_doesNotImmediatelyReDock() async throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.minX + 30, y: visible.midY,
                                    width: 240, height: 132))
        c.setHoveringForTesting(true)
        leaveAndSettle(c)
        XCTAssertTrue(c.isDockedForTesting)
        await awaitSlide(c)

        c.restoreFromDock()
        XCTAssertFalse(c.isDockedForTesting)
        leaveAndSettle(c)
        XCTAssertFalse(c.isDockedForTesting,
                       "a restore the user has not had a chance to use must survive")

        // Once it HAS been hovered, the next exit tucks it away again.
        c.setHoveringForTesting(true)
        leaveAndSettle(c)
        XCTAssertTrue(c.isDockedForTesting)
    }

    /// A restored panel sits beside the edge it came from, not at wherever it
    /// lived before docking — under auto-dock that would fling it across the
    /// screen on every peek.
    func testRestoreFromDock_staysBesideItsEdge() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY,
                                    width: 240, height: 132))
        c.settleAfterDrag()
        // Dock it to the left explicitly.
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 132))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting)

        c.restoreFromDock()
        XCTAssertLessThan(c.panelFrameForTesting.minX,
                          leftmostVisibleFrame.minX + FloatingCaptureGeometry.margin + 1,
                          "restores against the edge it was docked to")
    }

    /// The toggle lives on the ⋯ menu and reflects its state.
    func testOverflowMenu_carriesTheAutoDockToggle() {
        let c = makeController()
        let item = c.overflowMenuForTesting.items.first { $0.title.contains("Hide to Edge") }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.state, .off)
        c.autoDockEnabled = true
        let after = c.overflowMenuForTesting.items.first { $0.title.contains("Hide to Edge") }
        XCTAssertEqual(after?.state, .on)
    }

    /// Having slid the docked line to a spot they like, the user expects the
    /// panel to go back THERE — not to wherever the restored panel happened to
    /// sit.
    func testAutoDock_returnsToWhereTheLineWasLastParked() async throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 132))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting)

        // Slide the line along its edge to a chosen spot.
        let chosen = NSRect(x: visible.minX,
                            y: visible.minY + 80,
                            width: FloatingCaptureGeometry.dockedLineThickness,
                            height: FloatingCaptureGeometry.dockedLineLength)
        c.setFrameForTesting(chosen)
        c.settleAfterDrag()
        let parked = c.panelFrameForTesting

        c.autoDockEnabled = true
        c.restoreFromDock()
        XCTAssertFalse(c.isDockedForTesting)
        c.setHoveringForTesting(true)
        leaveAndSettle(c)
        XCTAssertTrue(c.isDockedForTesting)
        await awaitSlide(c)

        XCTAssertEqual(c.panelFrameForTesting.minY, parked.minY, accuracy: 1,
                       "back to the spot the line was parked at, not a fresh one")
    }

    /// …but DRAGGING the panel elsewhere drops that memory: it should tuck
    /// away near where the user put it, not fly back across the screen.
    func testAutoDock_forgetsTheOldSpotOnceThePanelIsDragged() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 132))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting, "remembered on the LEFT")
        c.restoreFromDock()

        c.autoDockEnabled = true
        // Drag the panel over to the RIGHT edge — a drag ENDS in a settle,
        // which is what tells auto-dock the old spot no longer applies.
        c.setFrameForTesting(NSRect(x: visible.maxX - 260, y: visible.midY,
                                    width: 240, height: 132))
        c.settleAfterDrag()
        c.setHoveringForTesting(true)
        leaveAndSettle(c)

        XCTAssertTrue(c.isDockedForTesting)
        XCTAssertEqual(c.dockedChevronSymbolForTesting, "chevron.left",
                       "docked on the right edge it was actually near")
    }

    /// Reported: with auto-hide on, the panel could not be dragged at all.
    /// Moving the window under the pointer fires `mouseExited`, which docked
    /// it mid-gesture.
    func testAutoDock_doesNotFireWhileThePanelIsBeingDragged() throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY,
                                    width: 240, height: 132))
        c.setHoveringForTesting(true)

        c.beginPanelDragForTesting(at: NSPoint(x: visible.midX + 20, y: visible.midY + 20))
        c.dragPanelForTesting(to: NSPoint(x: visible.midX + 120, y: visible.midY + 40))
        // The tracking area reports an exit as the window moves under it.
        leaveAndSettle(c)
        XCTAssertFalse(c.isDockedForTesting, "a drag must not be interrupted by auto-dock")

        c.endPanelDragForTesting()
        // Once the drag is over, leaving the panel tucks it away as usual.
        c.setHoveringForTesting(true)
        leaveAndSettle(c)
        XCTAssertTrue(c.isDockedForTesting)
    }

    /// Reported: after a cancelled capture the panel sits there with the
    /// pointer already elsewhere, so no exit event is coming. A click away is
    /// the clearest statement that the user is done with it.
    func testClickingAway_docksThePanel() throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY,
                                    width: 240, height: 132))

        c.clickAwayForTesting(at: NSPoint(x: visible.minX + 5, y: visible.minY + 5))
        XCTAssertTrue(c.isDockedForTesting)
    }

    /// A click ON the panel is not a click away — that is how its own buttons
    /// are pressed.
    func testClickingOnThePanel_doesNotDockIt() throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let frame = NSRect(x: visible.midX, y: visible.midY, width: 240, height: 132)
        c.setFrameForTesting(frame)

        c.clickAwayForTesting(at: NSPoint(x: frame.midX, y: frame.midY))
        XCTAssertFalse(c.isDockedForTesting)
    }

    func testClickingAway_doesNothingWhenAutoDockIsOff() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY,
                                    width: 240, height: 132))
        c.clickAwayForTesting(at: NSPoint(x: visible.minX + 5, y: visible.minY + 5))
        XCTAssertFalse(c.isDockedForTesting)
    }

    // MARK: Auto-dock is not trigger-happy

    /// Reported as "a little aggressive": crossing the panel's edge used to
    /// dock it on the spot. It now only ARMS a countdown.
    func testLeavingThePanel_doesNotDockImmediately() throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY,
                                    width: 240, height: 132))
        c.setHoveringForTesting(true)

        c.setHoveringForTesting(false)
        XCTAssertFalse(c.isDockedForTesting, "docking waits out the delay")
        XCTAssertTrue(c.autoDockIsPendingForTesting)
    }

    /// Passing OVER the panel on the way somewhere else: coming back cancels
    /// the countdown outright.
    func testReturningToThePanel_cancelsThePendingDock() throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY,
                                    width: 240, height: 132))
        c.setHoveringForTesting(true)
        c.setHoveringForTesting(false)
        XCTAssertTrue(c.autoDockIsPendingForTesting)

        c.setHoveringForTesting(true)
        XCTAssertFalse(c.autoDockIsPendingForTesting, "a return cancels it")
    }

    /// Working right beside the panel: the delay alone wouldn't help, since
    /// sitting two points outside still elapses. The pointer has to be clear
    /// of the panel by a margin when the countdown fires.
    func testPointerStillBesideThePanel_doesNotDockWhenTheDelayElapses() throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let frame = NSRect(x: visible.midX, y: visible.midY, width: 240, height: 132)
        c.setFrameForTesting(frame)
        c.setHoveringForTesting(true)
        c.setHoveringForTesting(false)

        // Just outside the edge — well within the margin.
        c.autoDockTimerFired(pointer: NSPoint(x: frame.maxX + 5, y: frame.midY))
        XCTAssertFalse(c.isDockedForTesting)

        // Beyond it, the same countdown docks.
        c.setHoveringForTesting(false)
        c.autoDockTimerFired(
            pointer: NSPoint(x: frame.maxX + FloatingCaptureController.autoDockDistance + 20,
                             y: frame.midY))
        XCTAssertTrue(c.isDockedForTesting)
    }

    /// A click elsewhere stays immediate — it is unambiguous, so it shouldn't
    /// wait out a delay meant for stray pointer movement.
    func testClickingAway_docksWithoutWaiting() throws {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: visible.midX, y: visible.midY,
                                    width: 240, height: 132))
        c.clickAwayForTesting(at: NSPoint(x: visible.minX + 5, y: visible.minY + 5))
        XCTAssertTrue(c.isDockedForTesting)
    }

    /// Reported: right after undocking, dragging the panel across displays
    /// made it jump to the edge for a moment and come back. The pointer-follow
    /// poll was carrying it to the new screen mid-drag, and the next drag
    /// event snapped it back under the cursor.
    func testDraggingAcrossDisplays_isNotFoughtByPointerFollow() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        // Cornered, which is what arms the follow.
        c.setFrameForTesting(NSRect(x: visible.minX + 4, y: visible.minY + 4,
                                    width: 240, height: 132))
        c.settleAfterDrag()
        XCTAssertTrue(c.isCorneredForTesting, "precondition: cornered, so following is armed")

        c.beginPanelDragForTesting(at: NSPoint(x: visible.minX + 60, y: visible.minY + 60))
        let midDrag = NSPoint(x: visible.midX, y: visible.midY)
        c.dragPanelForTesting(to: midDrag)
        let underCursor = c.panelFrameForTesting

        // A poll landing mid-drag with the pointer on ANOTHER display. It has
        // to be a real one: `followPointerIfNeeded` ignores a pointer that is
        // on no screen at all, so an off-canvas coordinate would make this
        // test pass with or without the fix.
        guard let other = NSScreen.screens.first(where: {
            $0.frame != (c.panelScreenFrameForTesting ?? visible)
        }), NSScreen.screens.count > 1 else {
            throw XCTSkip("needs a second display")
        }
        c.followPointerIfNeeded(pointer: NSPoint(x: other.frame.midX, y: other.frame.midY),
                                animated: false)

        XCTAssertEqual(c.panelFrameForTesting, underCursor,
                       "the panel stays where the hand put it")
        c.endPanelDragForTesting()
    }

    // MARK: Auto-reveal (hover the line to bring the panel back)

    /// Dock it, rest the pointer on the line, and it opens — auto-hide is not
    /// a one-way trip needing a click to undo.
    private func dockedController() throws -> FloatingCaptureController {
        let c = makeController()
        c.show()
        c.autoDockEnabled = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 132))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting, "precondition: docked")
        return c
    }

    func testHoveringTheDockedLine_revealsThePanel() throws {
        let c = try dockedController()
        let line = c.panelFrameForTesting
        let onLine = NSPoint(x: line.midX, y: line.midY)

        c.updateAutoReveal(pointer: onLine)
        XCTAssertTrue(c.autoRevealIsPendingForTesting, "the dwell has started")
        XCTAssertTrue(c.isDockedForTesting, "…but nothing opens yet")

        c.autoRevealTimerFired(pointer: onLine)
        XCTAssertFalse(c.isDockedForTesting, "resting on the line opens it")
    }

    /// Restoring is not dragging. A line parked near a corner restores to a
    /// frame beside its edge that happens to be within the corner-snap
    /// threshold — and snapping it there MOVED the panel every time the user
    /// peeked at it, which on auto-hide is constantly.
    func testRestoring_doesNotSnapThePanelIntoTheNearbyCorner() throws {
        let c = makeController()
        c.show()
        // Aiming past the left edge of EVERYTHING docks on the LEFTMOST
        // display — so every piece of expected geometry must come from that
        // screen too. The first version asked NSScreen.main, which is merely
        // "the screen with the key window": stable in a class run, but a full
        // suite's window churn flips it mid-test, and the assertion then
        // compared a correct leftmost-screen restore against another screen's
        // frame. (This suite has been bitten by exactly this before — the
        // multi-display docking tests all assert against the docking screen.)
        let dockScreen = try XCTUnwrap(
            NSScreen.screens.min(by: { $0.frame.minX < $1.frame.minX }))
        let visible = dockScreen.visibleFrame
        // Position so the restored panel lands 10pt above the snap margin —
        // inside the corner's catchment but NOT already at it. Docking at the
        // very bottom proves nothing: there the restored frame and the snapped
        // frame are the same rect, so the test passed with or without the fix.
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything,
                                    y: visible.minY + 24, width: 240, height: 132))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting, "precondition: docked near the corner")

        let line = c.panelFrameForTesting
        XCTAssertTrue(dockScreen.frame.intersects(line),
                      "precondition: the line lives on the leftmost screen")
        c.restoreFromDock()
        let restored = c.panelFrameForTesting
        let expected = FloatingCaptureGeometry.restoredFrame(
            from: line, edge: .left, size: NSSize(width: 240, height: 132), in: visible)
        XCTAssertEqual(restored, expected,
                       "the panel stays where restoring put it, un-snapped")
        XCTAssertNotEqual(restored.minY, visible.minY + FloatingCaptureGeometry.margin,
                          "precondition: the snap WOULD have moved it to the margin")
    }

    /// The panel grows out of the LINE the user is looking at. Starting the
    /// slide from the screen edge made it arrive from somewhere the line
    /// wasn't — a line can sit anywhere along its edge.
    func testTheRestoreSlide_startsFromTheLine() throws {
        let c = try dockedController()
        let line = c.panelFrameForTesting
        c.restoreFromDock(animated: true)
        XCTAssertEqual(c.panelFrameForTesting, line,
                       "the animation's first frame IS the line's frame")
    }

    /// Passing over the line on the way somewhere else must not open it.
    func testPointerLeavingBeforeTheDwellElapses_doesNotReveal() throws {
        let c = try dockedController()
        let line = c.panelFrameForTesting
        c.updateAutoReveal(pointer: NSPoint(x: line.midX, y: line.midY))
        XCTAssertTrue(c.autoRevealIsPendingForTesting)

        // Moved away before it fired.
        c.updateAutoReveal(pointer: NSPoint(x: line.maxX + 400, y: line.midY))
        XCTAssertFalse(c.autoRevealIsPendingForTesting, "the dwell is cancelled")
        XCTAssertTrue(c.isDockedForTesting)
    }

    /// Even if the timer somehow fires, a pointer that has moved on doesn't
    /// get a panel opened under it.
    func testDwellFiringAfterThePointerLeft_doesNotReveal() throws {
        let c = try dockedController()
        let line = c.panelFrameForTesting
        c.updateAutoReveal(pointer: NSPoint(x: line.midX, y: line.midY))
        c.autoRevealTimerFired(pointer: NSPoint(x: line.maxX + 400, y: line.midY))
        XCTAssertTrue(c.isDockedForTesting)
    }

    /// The line is thin, so the hot zone reaches a little past it.
    func testHotZone_reachesSlightlyPastTheLine() throws {
        let c = try dockedController()
        let line = c.panelFrameForTesting
        let justOutside = NSPoint(
            x: line.maxX + FloatingCaptureController.autoRevealMargin - 2, y: line.midY)
        c.updateAutoReveal(pointer: justOutside)
        XCTAssertTrue(c.autoRevealIsPendingForTesting)

        let wellOutside = NSPoint(
            x: line.maxX + FloatingCaptureController.autoRevealMargin + 20, y: line.midY)
        c.updateAutoReveal(pointer: wellOutside)
        XCTAssertFalse(c.autoRevealIsPendingForTesting)
    }

    /// With auto-hide off, a panel dragged to an edge stays put until clicked:
    /// the user parked it there deliberately.
    func testAutoRevealIsPartOfTheSameToggle() throws {
        let c = makeController()
        c.show()
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        c.setFrameForTesting(NSRect(x: pastLeftEdgeOfEverything, y: visible.midY,
                                    width: 240, height: 132))
        c.settleAfterDrag()
        XCTAssertTrue(c.isDockedForTesting)

        let line = c.panelFrameForTesting
        c.updateAutoReveal(pointer: NSPoint(x: line.midX, y: line.midY))
        XCTAssertFalse(c.autoRevealIsPendingForTesting)
        XCTAssertTrue(c.isDockedForTesting)
    }

    // MARK: Tooltips across a restore

    /// AppKit times the tooltip delay from the last pointer MOVEMENT, so the
    /// dwell spent opening the panel counts towards the tooltip of whatever
    /// lands under the pointer: panel and file name arrived together, naming a
    /// capture the user never pointed at. Tiles come back nameless.
    func testRevealingThePanel_doesNotAlsoNameTheTileUnderThePointer() async throws {
        let c = try dockedController()
        c.recentProvider = { [stripItem("/tmp/a.seal"), stripItem("/tmp/b.seal")] }
        await c.refreshStripForTesting()
        XCTAssertEqual(c.tileTooltipsForTesting, ["a.seal", "b.seal"], "named while docked")

        let line = c.panelFrameForTesting
        c.autoRevealTimerFired(pointer: NSPoint(x: line.midX, y: line.midY))
        XCTAssertFalse(c.isDockedForTesting, "it opened")
        XCTAssertEqual(c.tileTooltipsForTesting, [nil, nil], "…without naming anything")
    }

    /// The file name is worth having — once the pointer is deliberately on a
    /// tile. Moving it is both the user's statement of intent and the moment
    /// AppKit restarts its own delay.
    func testMovingThePointerAfterAReveal_bringsTheNamesBack() async throws {
        let c = try dockedController()
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        let line = c.panelFrameForTesting
        c.autoRevealTimerFired(pointer: NSPoint(x: line.midX, y: line.midY))
        XCTAssertEqual(c.tileTooltipsForTesting, [nil])

        let here = NSEvent.mouseLocation
        c.pointerMovedForTesting(to: NSPoint(
            x: here.x + FloatingCaptureController.tooltipWakeDistance + 6, y: here.y))
        XCTAssertEqual(c.tileTooltipsForTesting, ["a.seal"])
    }

    /// Hand tremor is not pointing. A pointer that has barely twitched has not
    /// left the spot it was resting on to open the panel.
    func testATinyTwitchAfterAReveal_doesNotBringTheNamesBack() async throws {
        let c = try dockedController()
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        let line = c.panelFrameForTesting
        c.autoRevealTimerFired(pointer: NSPoint(x: line.midX, y: line.midY))

        let here = NSEvent.mouseLocation
        c.pointerMovedForTesting(to: NSPoint(x: here.x + 1, y: here.y + 1))
        XCTAssertTrue(c.tileTooltipsSuppressedForTesting)
        XCTAssertEqual(c.tileTooltipsForTesting, [nil])
    }

    /// Tiles built WHILE suppressed — a capture landing in the moment between
    /// the reveal and the pointer moving — must be nameless too, or the strip
    /// refresh quietly undoes the suppression.
    func testATileBuiltDuringSuppression_isNamelessToo() async throws {
        let c = try dockedController()
        c.recentProvider = { [stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        let line = c.panelFrameForTesting
        c.autoRevealTimerFired(pointer: NSPoint(x: line.midX, y: line.midY))

        c.recentProvider = { [stripItem("/tmp/fresh.seal"), stripItem("/tmp/a.seal")] }
        await c.refreshStripForTesting()
        XCTAssertEqual(c.tileTooltipsForTesting, [nil, nil])
    }
}
