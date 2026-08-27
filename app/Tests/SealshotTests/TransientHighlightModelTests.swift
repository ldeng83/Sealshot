import XCTest
@testable import Sealshot

final class ActivityHighlightDismissalTests: XCTestCase {
    private func url(_ n: Int) -> URL { URL(fileURLWithPath: "/save/\(n).seal") }
    private func key(_ n: Int) -> String { url(n).activityHighlightKey }

    func test_noMarks_neverDismisses() {
        XCTAssertFalse(ActivityHighlightDismissal.shouldDismiss(marked: [], clicked: key(1)))
        XCTAssertFalse(ActivityHighlightDismissal.shouldDismiss(marked: [], clicked: nil))
    }

    func test_clickEmptySpace_dismisses() {
        XCTAssertTrue(ActivityHighlightDismissal.shouldDismiss(marked: [key(1)], clicked: nil))
    }

    func test_clickMarkedItem_keeps() {
        XCTAssertFalse(ActivityHighlightDismissal.shouldDismiss(marked: [key(1), key(2)], clicked: key(2)))
    }

    func test_clickNonMarkedItem_dismisses() {
        XCTAssertTrue(ActivityHighlightDismissal.shouldDismiss(marked: [key(1)], clicked: key(9)))
    }

    func test_activityKey_matchesAcrossURLConstructions() {
        // The bug: a file URL built via appendingPathComponent vs fileURLWithPath
        // can be != as URLs but is the same file — keys must match.
        let viaAppend = URL(fileURLWithPath: "/save", isDirectory: true)
            .appendingPathComponent("My Shot · 1.seal")
        let viaPath = URL(fileURLWithPath: "/save/My Shot · 1.seal")
        XCTAssertEqual(viaAppend.activityHighlightKey, viaPath.activityHighlightKey)
    }
}

@MainActor
final class ActivityHighlightStoreTests: XCTestCase {
    private func url(_ n: Int) -> URL { URL(fileURLWithPath: "/save/\(n).seal") }

    func test_mark_accumulatesAcrossCalls() {
        let store = ActivityHighlightStore()
        store.mark([url(1)])
        store.mark([url(2), url(3)])
        XCTAssertTrue(store.contains(url(1)))
        XCTAssertTrue(store.contains(url(2)))
        XCTAssertTrue(store.contains(url(3)))
        XCTAssertEqual(store.keys.count, 3)
    }

    func test_dismiss_clearsAll_onClickOutside() {
        let store = ActivityHighlightStore()
        store.mark([url(1), url(2)])
        store.dismiss(clicked: url(9))   // not marked → clears everything
        XCTAssertTrue(store.keys.isEmpty)
    }

    func test_dismiss_keepsAll_onClickMarked() {
        let store = ActivityHighlightStore()
        store.mark([url(1), url(2)])
        store.dismiss(clicked: url(2))   // marked → keep
        XCTAssertEqual(store.keys.count, 2)
    }

    func test_mark_emptyIsNoOp() {
        let store = ActivityHighlightStore()
        store.mark([])
        XCTAssertTrue(store.keys.isEmpty)
    }
}
