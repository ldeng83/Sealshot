import XCTest
@testable import Sealshot

final class PendingOpenQueueTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(fileURLWithPath: s) }

    func test_startsEmpty() {
        let q = PendingOpenQueue()
        XCTAssertTrue(q.isEmpty)
    }

    func test_enqueueAccumulatesAcrossCalls() {
        var q = PendingOpenQueue()
        q.enqueue([url("/a.png")])
        q.enqueue([url("/b.png"), url("/c.png")])
        XCTAssertFalse(q.isEmpty)
        XCTAssertEqual(q.urls, [url("/a.png"), url("/b.png"), url("/c.png")])
    }

    func test_drainReturnsAllAndEmpties() {
        var q = PendingOpenQueue()
        q.enqueue([url("/a.png"), url("/b.png")])
        let drained = q.drain()
        XCTAssertEqual(drained, [url("/a.png"), url("/b.png")])
        XCTAssertTrue(q.isEmpty)
    }

    func test_drainOnEmptyReturnsEmpty() {
        var q = PendingOpenQueue()
        XCTAssertEqual(q.drain(), [])
    }

    func test_queueIsReusableAfterDrain() {
        var q = PendingOpenQueue()
        q.enqueue([url("/a.png")])
        _ = q.drain()
        q.enqueue([url("/b.png")])
        XCTAssertEqual(q.drain(), [url("/b.png")])
    }
}
