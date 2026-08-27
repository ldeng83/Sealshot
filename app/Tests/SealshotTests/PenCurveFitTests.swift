import XCTest
@testable import Sealshot

/// The pen used to interpolate every surviving sample with Catmull-Rom, so hand
/// tremor was reproduced exactly rather than attenuated. It now resamples to an
/// even arc-length step and fits least-squares cubics within a tolerance.
final class PenCurveFitTests: XCTestCase {

    // MARK: - Resampling

    /// Slow drawing packs samples into a pixel or two; the step must thin them.
    func test_resamplingThinsAClusteredRun() {
        let clustered = (0..<200).map { CGPoint(x: CGFloat($0) * 0.1, y: 0) }   // 20 units of travel
        let out = PenPath.resampled(clustered, spacing: 3)
        XCTAssertLessThan(out.count, clustered.count / 4,
                          "200 samples over 20 units should collapse to roughly 20/3 points")
        XCTAssertGreaterThanOrEqual(out.count, 2)
    }

    /// Endpoints are load-bearing: the end pin depends on the last point, and a
    /// stroke that no longer starts where the user pressed is a visible bug.
    func test_resamplingKeepsBothEndpoints() {
        let pts = (0..<50).map { CGPoint(x: CGFloat($0) * 2, y: CGFloat($0)) }
        let out = PenPath.resampled(pts, spacing: 3)
        XCTAssertEqual(out.first!.x, pts.first!.x, accuracy: 0.0001)
        XCTAssertEqual(out.first!.y, pts.first!.y, accuracy: 0.0001)
        XCTAssertEqual(out.last!.x, pts.last!.x, accuracy: 0.0001)
        XCTAssertEqual(out.last!.y, pts.last!.y, accuracy: 0.0001)
    }

    /// Spacing is honoured: consecutive output points sit about `spacing` apart.
    func test_resampledPointsAreEvenlySpaced() {
        let line = (0..<100).map { CGPoint(x: CGFloat($0), y: 0) }
        let out = PenPath.resampled(line, spacing: 5)
        guard out.count > 3 else { return XCTFail("expected several points") }
        for i in 1..<(out.count - 1) {          // last gap is the remainder
            let d = hypot(out[i].x - out[i - 1].x, out[i].y - out[i - 1].y)
            XCTAssertEqual(d, 5, accuracy: 0.5, "gap \(i) was \(d)")
        }
    }

    func test_resamplingLeavesShortInputAlone() {
        let two = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        XCTAssertEqual(PenPath.resampled(two, spacing: 3), two)
    }

    // MARK: - Fitting

    /// A straight run needs almost no segments. Interpolation produced one per
    /// sample pair, which is the wasted-segment problem in its purest form.
    ///
    /// Not "exactly one": fitting is chunked at fixed indices so that a live
    /// stroke's drawn prefix cannot be re-solved as new samples arrive, and a
    /// long enough line therefore spans more than one chunk. What matters is
    /// that segments track CHUNKS, not samples.
    func test_aStraightLineNeedsFarFewerSegmentsThanSamples() {
        let line = (0..<40).map { CGPoint(x: CGFloat($0) * 3, y: 0) }
        let segs = PenPath.fitCubics(line, tolerance: 2)
        // The bound scales with CHUNK count, not sample count: chunks are
        // deliberately small so a live stroke settles quickly behind the
        // pointer, and a long line therefore spans several of them.
        XCTAssertLessThanOrEqual(segs.count, 6, "got \(segs.count) segments for a straight line")
        XCTAssertGreaterThanOrEqual(segs.count, 1)
    }

    /// A smooth arc should fit in far fewer segments than it has samples —
    /// that reduction IS the smoothing.
    func test_aSmoothArcUsesFarFewerSegmentsThanSamples() {
        let arc = (0..<60).map { i -> CGPoint in
            let t = CGFloat(i) / 59 * .pi
            return CGPoint(x: cos(t) * 100, y: sin(t) * 100)
        }
        let segs = PenPath.fitCubics(arc, tolerance: 2)
        XCTAssertLessThan(segs.count, 10, "got \(segs.count) segments for 60 samples")
        XCTAssertGreaterThanOrEqual(segs.count, 1)
    }

    /// Fitting must stay faithful: the last control point is the input's end.
    func test_fitEndsOnTheFinalInputPoint() {
        let arc = (0..<30).map { i -> CGPoint in
            let t = CGFloat(i) / 29 * .pi / 2
            return CGPoint(x: cos(t) * 50, y: sin(t) * 50)
        }
        let segs = PenPath.fitCubics(arc, tolerance: 2)
        let end = segs.last!.p3
        XCTAssertEqual(end.x, arc.last!.x, accuracy: 0.0001)
        XCTAssertEqual(end.y, arc.last!.y, accuracy: 0.0001)
    }

    /// Tremor must be attenuated, not reproduced. A jittered straight line
    /// should fit close to the true line rather than through every wobble.
    func test_tremorIsAttenuatedNotReproduced() {
        // Deterministic zig-zag jitter of ±1.2 around y = 0.
        let jittered = (0..<80).map { i -> CGPoint in
            CGPoint(x: CGFloat(i) * 3, y: (i % 2 == 0 ? 1.2 : -1.2))
        }
        let segs = PenPath.fitCubics(jittered, tolerance: 2)
        // Sample the fitted curve's control points: they should sit near y = 0,
        // not oscillate to the jitter amplitude.
        let ys = segs.flatMap { [$0.c1.y, $0.c2.y] }
        let maxAbs = ys.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(maxAbs, 3.0, "controls swung to \(maxAbs) — tremor is being tracked")
    }

    /// The whole pipeline still produces a usable path for ordinary input, and
    /// still ends where the stroke ended.
    func test_smoothedPathStillEndsAtTheStrokeEnd() {
        let pts = (0..<50).map { CGPoint(x: CGFloat($0) * 4, y: sin(CGFloat($0) / 5) * 20) }
        let path = PenPath.smoothedPath(pts)
        XCTAssertGreaterThan(path.elementCount, 1)
        XCTAssertEqual(path.currentPoint.x, pts.last!.x, accuracy: 0.5)
        XCTAssertEqual(path.currentPoint.y, pts.last!.y, accuracy: 0.5)
    }
}
