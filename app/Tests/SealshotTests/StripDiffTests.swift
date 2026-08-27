import XCTest
@testable import Sealshot

final class StripDiffTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/captures/\(name).seal")
    }

    func test_noChange() {
        let urls = [url("a"), url("b")]
        let diff = stripDiff(old: urls, new: urls)
        XCTAssertEqual(diff, StripDiffResult(removed: [], inserted: [], orderChanged: false))
    }

    func test_prepend_newCapture() {
        let diff = stripDiff(old: [url("a"), url("b")], new: [url("c"), url("a"), url("b")])
        XCTAssertEqual(diff.inserted, [url("c")])
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertFalse(diff.orderChanged)
    }

    func test_removal() {
        let diff = stripDiff(old: [url("a"), url("b"), url("c")], new: [url("a"), url("c")])
        XCTAssertEqual(diff.removed, [url("b")])
        XCTAssertTrue(diff.inserted.isEmpty)
        XCTAssertFalse(diff.orderChanged)
    }

    func test_move_setsOrderChanged() {
        let diff = stripDiff(old: [url("a"), url("b")], new: [url("b"), url("a")])
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.inserted.isEmpty)
        XCTAssertTrue(diff.orderChanged)
    }

    func test_mixed() {
        let diff = stripDiff(old: [url("a"), url("b"), url("c")],
                             new: [url("d"), url("c"), url("a")])
        XCTAssertEqual(diff.removed, [url("b")])
        XCTAssertEqual(diff.inserted, [url("d")])
        XCTAssertTrue(diff.orderChanged)
    }

    func test_rotation_setsOrderChanged() {
        let diff = stripDiff(old: [url("a"), url("b"), url("c")],
                             new: [url("c"), url("a"), url("b")])
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.inserted.isEmpty)
        XCTAssertTrue(diff.orderChanged)
    }

    func test_interiorInsert_doesNotTripOrderChanged() {
        let diff = stripDiff(old: [url("a"), url("c")],
                             new: [url("a"), url("b"), url("c")])
        XCTAssertEqual(diff.inserted, [url("b")])
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertFalse(diff.orderChanged)
    }

    func test_emptyToFull_andBack() {
        let grow = stripDiff(old: [], new: [url("a")])
        XCTAssertEqual(grow.inserted, [url("a")])
        XCTAssertFalse(grow.orderChanged)
        let shrink = stripDiff(old: [url("a")], new: [])
        XCTAssertEqual(shrink.removed, [url("a")])
        XCTAssertFalse(shrink.orderChanged)
    }
}
