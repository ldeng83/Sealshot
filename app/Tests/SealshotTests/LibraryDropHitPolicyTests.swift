import AppKit
import XCTest
@testable import Sealshot

/// Which sidebar row a capture drop lands on. The drop destination sits on the
/// window's content view — an ancestor of every row — so this geometry is the
/// only thing deciding which row answers, and a wrong answer files captures
/// into the wrong collection.
final class LibraryDropHitPolicyTests: XCTestCase {

    private let row = NSRect(x: 0, y: 100, width: 220, height: 28)
    private let sidebarClip = NSRect(x: 0, y: 0, width: 220, height: 600)

    private func accepts(_ point: NSPoint,
                         row: NSRect? = nil,
                         visible: NSRect? = nil,
                         hidden: Bool = false) -> Bool {
        LibraryDropHitPolicy.accepts(boundsInWindow: row ?? self.row,
                                     visibleRectInWindow: visible ?? sidebarClip,
                                     point: point, isHidden: hidden)
    }

    func testDropInsideTheRow_isAccepted() {
        XCTAssertTrue(accepts(NSPoint(x: 110, y: 114)))
    }

    func testDropOutsideTheRow_isRefused() {
        XCTAssertFalse(accepts(NSPoint(x: 110, y: 60)), "below the row")
        XCTAssertFalse(accepts(NSPoint(x: 110, y: 200)), "above the row")
        XCTAssertFalse(accepts(NSPoint(x: 400, y: 114)), "right of the sidebar")
    }

    /// Adjacent rows must not both answer: a drop lands in exactly one
    /// collection, and the boundary is where an off-by-one would put it in the
    /// wrong one.
    func testAdjacentRows_neverBothAccept() {
        let upper = NSRect(x: 0, y: 128, width: 220, height: 28)
        let lower = NSRect(x: 0, y: 100, width: 220, height: 28)
        for y in stride(from: 100.0, through: 156.0, by: 0.5) {
            let point = NSPoint(x: 110, y: y)
            let inUpper = accepts(point, row: upper)
            let inLower = accepts(point, row: lower)
            XCTAssertFalse(inUpper && inLower,
                           "y=\(y) matched both rows")
        }
    }

    /// Editor and Library are tabs in ONE window and the destination is on the
    /// shared content view, so a row left registered while the Library is
    /// hidden must not answer for a drop over the editor canvas.
    func testRowLeftRegisteredWhileTheLibraryIsHidden_isRefused() {
        XCTAssertFalse(accepts(NSPoint(x: 110, y: 114), visible: .zero),
                       "an empty clip means the Library is not on screen")
        XCTAssertFalse(accepts(NSPoint(x: 110, y: 114), hidden: true))
    }

    /// A drop inside the row's frame but scrolled out of the sidebar's clip is
    /// not on screen, so it cannot be a target.
    func testRowScrolledOutOfTheClip_isRefused() {
        let clipBelowRow = NSRect(x: 0, y: 0, width: 220, height: 90)
        XCTAssertFalse(accepts(NSPoint(x: 110, y: 114), visible: clipBelowRow))
    }
}

/// The registry the destination consults. Registration is by view, so a row
/// that goes away must stop answering — SwiftUI rebuilds these constantly.
@MainActor
final class LibraryDropMonitorTests: XCTestCase {

    func testUnregisteredPoint_hasNoHandler() {
        XCTAssertNil(LibraryDropMonitor.shared.handler(at: NSPoint(x: -9_000, y: -9_000)),
                     "a drop away from every row must refuse, so the drag bounces as before")
    }

    /// A row whose view is gone must not keep answering for its old frame.
    func testDeallocatedRow_isDroppedFromTheRegistry() {
        var view: LibraryDropTargetView? = LibraryDropTargetView()
        LibraryDropMonitor.shared.register(view!) { _ in }
        view = nil
        // The entry's view is weak; resolving prunes it rather than crashing.
        XCTAssertNil(LibraryDropMonitor.shared.handler(at: NSPoint(x: 5, y: 5)))
    }

    /// The row contributes a frame and a highlight only — it must never take
    /// mouse events, or selecting and renaming a collection would break.
    func testRowRegistrantIsInvisibleToTheMouse() {
        let view = LibraryDropTargetView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 14)))
    }
}
