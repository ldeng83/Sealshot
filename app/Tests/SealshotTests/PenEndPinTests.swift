import XCTest
@testable import Sealshot

/// The streamline filter lags its input, so the last filtered point falls short
/// of where the pointer stopped. Overwriting only that point closed the entire
/// accumulated lag in one step and left a hook at the end of every stroke; the
/// correction is now spread across the tail.
final class PenEndPinTests: XCTestCase {

    /// A stroke that travels fast in a straight line — the filter lags most here.
    private func fastLine(_ n: Int = 40, step: CGFloat = 12) -> [CGPoint] {
        (0..<n).map { CGPoint(x: CGFloat($0) * step, y: 0) }
    }

    /// The whole point of the end pin: the stroke must still finish exactly
    /// where the pointer did.
    func test_strokeStillEndsExactlyAtTheRawFinalPoint() {
        let raw = fastLine()
        let out = PenPath.streamlined(raw)
        XCTAssertEqual(out.last!.x, raw.last!.x, accuracy: 0.0001)
        XCTAssertEqual(out.last!.y, raw.last!.y, accuracy: 0.0001)
    }

    /// The kink test. With the correction applied to a single point, the final
    /// segment is far longer than its neighbour — that length spike IS the
    /// hook. Spread across the tail, consecutive tail segments stay comparable.
    func test_finalSegmentIsNotAnOutlierInLength() {
        let out = PenPath.streamlined(fastLine())
        func len(_ i: Int) -> CGFloat {
            hypot(out[i].x - out[i - 1].x, out[i].y - out[i - 1].y)
        }
        let last = len(out.count - 1)
        let prev = len(out.count - 2)
        XCTAssertLessThan(last, prev * 2.0,
                          "final segment \(last) vs previous \(prev) — a spike here is the end hook")
    }

    /// The correction must actually be distributed, not just applied at the end:
    /// interior tail points move toward the raw track too.
    func test_correctionIsSpreadAcrossTheTailNotDumpedOnTheLastPoint() {
        let raw = fastLine()
        let out = PenPath.streamlined(raw)
        // Second-to-last point should have been pulled forward as well, so it
        // sits closer to the raw track than the unramped filter would leave it.
        let secondLast = out[out.count - 2]
        let rawSecondLast = raw[raw.count - 2]
        XCTAssertLessThan(abs(secondLast.x - rawSecondLast.x),
                          abs(raw.last!.x - rawSecondLast.x),
                          "tail points must share the correction")
    }

    /// Short strokes must not crash or over-correct when there are fewer points
    /// than the ramp length.
    func test_shortStrokeIsHandled() {
        for n in 3...8 {
            let raw = (0..<n).map { CGPoint(x: CGFloat($0) * 5, y: 0) }
            let out = PenPath.streamlined(raw)
            XCTAssertEqual(out.count, raw.count)
            XCTAssertEqual(out.last!.x, raw.last!.x, accuracy: 0.0001)
        }
    }

    /// Degenerate inputs keep their existing contract.
    func test_twoOrFewerPointsPassThrough() {
        XCTAssertEqual(PenPath.streamlined([]).count, 0)
        let one = [CGPoint(x: 3, y: 4)]
        XCTAssertEqual(PenPath.streamlined(one), one)
        let two = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        XCTAssertEqual(PenPath.streamlined(two), two)
    }
}
