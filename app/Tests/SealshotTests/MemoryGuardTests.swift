import XCTest
@testable import Sealshot

@MainActor
final class MemoryGuardTests: XCTestCase {

    func test_firesOnceWhenCrossingThreshold_andReArmsAfterRecovery() {
        var fp: UInt64 = 0
        var fires = 0
        let guardian = MemoryGuard(warnBytes: 1_000, footprint: { fp })
        guardian.onHighMemory = { fires += 1 }

        fp = 500;  XCTAssertFalse(guardian.evaluate()); XCTAssertEqual(fires, 0)   // below
        fp = 1_200; XCTAssertTrue(guardian.evaluate());  XCTAssertEqual(fires, 1)   // cross → fire
        fp = 1_300; XCTAssertFalse(guardian.evaluate()); XCTAssertEqual(fires, 1)   // still high → no re-fire
        fp = 600;  XCTAssertFalse(guardian.evaluate()); XCTAssertEqual(fires, 1)   // below 75% → re-arm
        fp = 1_100; XCTAssertTrue(guardian.evaluate());  XCTAssertEqual(fires, 2)   // cross again → fire
    }

    func test_footprint_returnsNonZeroForRunningProcess() {
        XCTAssertGreaterThan(MemoryGuard.footprint(), 0)
    }
}
