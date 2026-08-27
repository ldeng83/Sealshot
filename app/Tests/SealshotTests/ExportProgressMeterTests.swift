import XCTest
@testable import Sealshot

final class ExportProgressMeterTests: XCTestCase {
    func testCounterAccumulates() {
        let c = ProgressCounter(); c.add(100); c.add(50)
        XCTAssertEqual(c.current, 150)
    }
    func testFractionClamped() {
        let m = ExportProgressMeter(totalBytes: 1000, start: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.sample(done: 0,    now: Date(timeIntervalSince1970: 2)).fraction, 0,   accuracy: 1e-9)
        XCTAssertEqual(m.sample(done: 500,  now: Date(timeIntervalSince1970: 2)).fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.sample(done: 5000, now: Date(timeIntervalSince1970: 2)).fraction, 1.0, accuracy: 1e-9)
    }
    func testETASuppressedUntilStable() {
        let m = ExportProgressMeter(totalBytes: 1000, start: Date(timeIntervalSince1970: 0))
        XCTAssertNil(m.sample(done: 5,   now: Date(timeIntervalSince1970: 2)).eta)   // <3%
        XCTAssertNil(m.sample(done: 500, now: Date(timeIntervalSince1970: 0.5)).eta) // <1s
    }
    func testETAComputed() {
        let m = ExportProgressMeter(totalBytes: 1000, start: Date(timeIntervalSince1970: 0))
        // 25% in 2s → remaining 75% takes 6s
        let eta = m.sample(done: 250, now: Date(timeIntervalSince1970: 2)).eta
        XCTAssertEqual(try XCTUnwrap(eta), 6, accuracy: 1e-6)
    }
    func testETAText() {
        XCTAssertEqual(ExportProgressMeter.etaText(5), "a few seconds left")
        XCTAssertEqual(ExportProgressMeter.etaText(22), "about 20s left")
        XCTAssertEqual(ExportProgressMeter.etaText(130), "about 2 min left")
        XCTAssertNil(ExportProgressMeter.etaText(nil))
    }
    func testZeroTotal() {
        let m = ExportProgressMeter(totalBytes: 0, start: Date(timeIntervalSince1970: 0))
        let s = m.sample(done: 0, now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(s.fraction, 0); XCTAssertNil(s.eta)
    }
}
