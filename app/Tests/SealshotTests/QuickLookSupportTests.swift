import XCTest
@testable import Sealshot

final class QuickLookSupportTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(fileURLWithPath: s) }

    // MARK: QuickLookToggle

    func test_toggle_openWhenOneSelected_closes() {
        let r = QuickLookToggle.resolve(currentlyOpen: true, selection: [u("/a")], anchor: u("/a"), firstItem: u("/a"))
        XCTAssertEqual(r, .init(open: false, selectURL: nil))
    }

    func test_toggle_closedWithOneSelected_opensNoReselect() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [u("/a")], anchor: u("/a"), firstItem: u("/a"))
        XCTAssertEqual(r, .init(open: true, selectURL: nil))
    }

    func test_toggle_closedNoSelection_selectsFirstAndOpens() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [], anchor: nil, firstItem: u("/first"))
        XCTAssertEqual(r, .init(open: true, selectURL: u("/first")))
    }

    func test_toggle_closedNoSelectionEmptyList_staysClosed() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [], anchor: nil, firstItem: nil)
        XCTAssertEqual(r, .init(open: false, selectURL: nil))
    }

    func test_toggle_closedManySelected_opensPreviewingAnchor() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [u("/a"), u("/b")], anchor: u("/b"), firstItem: u("/a"))
        XCTAssertEqual(r, .init(open: true, selectURL: u("/b")))
    }

    func test_toggle_closedManySelectedNoAnchor_opensPreviewingASelected() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [u("/a"), u("/b")], anchor: nil, firstItem: u("/a"))
        // With no anchor, collapse to a deterministic selected URL (sorted-first).
        XCTAssertEqual(r, .init(open: true, selectURL: u("/a")))
    }

}
