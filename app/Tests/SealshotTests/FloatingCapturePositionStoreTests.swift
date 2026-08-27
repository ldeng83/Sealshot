import XCTest
@testable import Sealshot

final class FloatingCapturePositionStoreTests: XCTestCase {

    private let suite = "FloatingCapturePositionStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFrame_unknownDisplay_isNil() {
        let store = FloatingCapturePositionStore(defaults: defaults)
        XCTAssertNil(store.frame(forDisplay: "never-seen"))
    }

    func testSetFrame_roundTripsForThatDisplay() {
        var store = FloatingCapturePositionStore(defaults: defaults)
        let frame = CGRect(x: 12, y: 34, width: 120, height: 70)
        store.setFrame(frame, forDisplay: "display-A")
        XCTAssertEqual(store.frame(forDisplay: "display-A"), frame)
    }

    func testSetFrame_isScopedPerDisplay() {
        var store = FloatingCapturePositionStore(defaults: defaults)
        store.setFrame(CGRect(x: 12, y: 34, width: 120, height: 70), forDisplay: "display-A")
        XCTAssertNil(store.frame(forDisplay: "display-B"))
    }

    func testSetFrame_secondDisplayDoesNotEvictTheFirst() {
        var store = FloatingCapturePositionStore(defaults: defaults)
        let a = CGRect(x: 1, y: 2, width: 120, height: 70)
        let b = CGRect(x: 300, y: 400, width: 120, height: 70)
        store.setFrame(a, forDisplay: "display-A")
        store.setFrame(b, forDisplay: "display-B")
        XCTAssertEqual(store.frame(forDisplay: "display-A"), a)
        XCTAssertEqual(store.frame(forDisplay: "display-B"), b)
    }

    func testFrame_survivesANewStoreOverTheSameDefaults() {
        var writer = FloatingCapturePositionStore(defaults: defaults)
        let frame = CGRect(x: 1, y: 2, width: 120, height: 70)
        writer.setFrame(frame, forDisplay: "display-A")
        let reader = FloatingCapturePositionStore(defaults: defaults)
        XCTAssertEqual(reader.frame(forDisplay: "display-A"), frame)
    }

    // MARK: Validation

    func testValidated_frameOnAnAttachedScreen_isKept() {
        let frame = CGRect(x: 20, y: 20, width: 120, height: 70)
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 775)]
        XCTAssertEqual(FloatingCapturePositionStore.validated(frame, against: screens), frame)
    }

    /// The unplugged-monitor case: a remembered frame that now lies on no
    /// screen must be discarded, not restored off-screen.
    func testValidated_frameOnNoAttachedScreen_isDiscarded() {
        let frame = CGRect(x: 3000, y: 20, width: 120, height: 70)
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 775)]
        XCTAssertNil(FloatingCapturePositionStore.validated(frame, against: screens))
    }

    /// Partially off an edge is still recoverable — only fully-adrift frames
    /// are thrown away.
    func testValidated_frameOverlappingAnEdge_isKept() {
        let frame = CGRect(x: 960, y: 20, width: 120, height: 70)
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 775)]
        XCTAssertEqual(FloatingCapturePositionStore.validated(frame, against: screens), frame)
    }

    func testValidated_nil_staysNil() {
        XCTAssertNil(FloatingCapturePositionStore.validated(nil, against: [.zero]))
    }

    // MARK: Docked state (survives a restart)

    func testDockState_unknownDisplay_isNil() {
        let store = FloatingCapturePositionStore(defaults: defaults)
        XCTAssertNil(store.dockState(forDisplay: "never-seen"))
    }

    func testDockState_roundTrips() {
        var store = FloatingCapturePositionStore(defaults: defaults)
        let state = FloatingCapturePositionStore.DockedState(
            edge: .right,
            line: CGRect(x: 1900, y: 400, width: 18, height: 64),
            panelSize: CGSize(width: 240, height: 132))
        store.setDockState(state, forDisplay: "display-1")
        XCTAssertEqual(store.dockState(forDisplay: "display-1"), state)
        XCTAssertNil(store.dockState(forDisplay: "display-2"),
                     "docking on one screen says nothing about another")
    }

    /// The pre-dock size rides along: a click on the restored line has to
    /// reopen the panel at its old size, not at the line's 18pt.
    func testDockState_keepsThePanelSizeItHadBeforeDocking() {
        var store = FloatingCapturePositionStore(defaults: defaults)
        store.setDockState(.init(edge: .bottom,
                                 line: CGRect(x: 300, y: 0, width: 64, height: 18),
                                 panelSize: CGSize(width: 240, height: 132)),
                           forDisplay: "d")
        XCTAssertEqual(store.dockState(forDisplay: "d")?.panelSize,
                       CGSize(width: 240, height: 132))
    }

    func testClearDockState_forgetsIt() {
        var store = FloatingCapturePositionStore(defaults: defaults)
        store.setDockState(.init(edge: .left,
                                 line: CGRect(x: 0, y: 100, width: 18, height: 64),
                                 panelSize: CGSize(width: 240, height: 132)),
                           forDisplay: "d")
        store.clearDockState(forDisplay: "d")
        XCTAssertNil(store.dockState(forDisplay: "d"))
    }

    /// Reset Position has to clear the dock for displays that are not attached
    /// right now: a dock remembered for the monitor you just unplugged is
    /// exactly what would put the panel back out of reach at next launch.
    func testClearAllDockStates_forgetsEveryDisplay() {
        var store = FloatingCapturePositionStore(defaults: defaults)
        let state = FloatingCapturePositionStore.DockedState(
            edge: .left, line: CGRect(x: 0, y: 100, width: 18, height: 64),
            panelSize: CGSize(width: 240, height: 132))
        store.setDockState(state, forDisplay: "here")
        store.setDockState(state, forDisplay: "unplugged")
        store.clearAllDockStates()
        XCTAssertNil(store.dockState(forDisplay: "here"))
        XCTAssertNil(store.dockState(forDisplay: "unplugged"))
    }

    func testDockState_ignoresMalformedStorage() {
        defaults.set(["d": "nonsense"], forKey: "FloatingCaptureWindowDock")
        let store = FloatingCapturePositionStore(defaults: defaults)
        XCTAssertNil(store.dockState(forDisplay: "d"))
    }

    /// The edge is persisted by raw value — renaming a case would silently
    /// drop every remembered dock.
    func testDockEdgeRawValues_areStable() {
        XCTAssertEqual(FloatingCaptureGeometry.DockEdge.left.rawValue, "left")
        XCTAssertEqual(FloatingCaptureGeometry.DockEdge.right.rawValue, "right")
        XCTAssertEqual(FloatingCaptureGeometry.DockEdge.top.rawValue, "top")
        XCTAssertEqual(FloatingCaptureGeometry.DockEdge.bottom.rawValue, "bottom")
    }
}
