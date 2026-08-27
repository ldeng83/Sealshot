import XCTest
@testable import Sealshot

/// A live stroke and a finished one want opposite things, so they get separate
/// settings instead of one compromise.
///
/// While drawing, anything that smooths hard also lags the pointer or shifts
/// the line already on screen — both read as "jelly". After release nothing
/// more is arriving, so the stroke can be smoothed properly and fit as one
/// span with no chunk seams. The stroke settles as it commits; that is the
/// intended behaviour, not a glitch.
final class PenProfileTests: XCTestCase {

    /// A tremulous stroke, like a real hand.
    private func stroke(_ n: Int = 160) -> [CGPoint] {
        (0..<n).map { i -> CGPoint in
            let t = CGFloat(i) / 25
            return CGPoint(x: t * 90 + sin(CGFloat(i) * 2.7) * 0.9,
                           y: sin(t) * 70 + cos(CGFloat(i) * 3.1) * 0.9)
        }
    }

    private func polyline(_ path: NSBezierPath) -> [CGPoint] {
        let flat = path.flattened
        var out: [CGPoint] = []
        var p = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &p) {
            case .moveTo, .lineTo: out.append(p[0])
            default: break
            }
        }
        return out
    }

    /// Total turning of the rendered curve: a shakier line changes direction
    /// more, so this drops as smoothing rises. A direct measure of "smooth".
    private func totalTurning(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 2 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<(pts.count - 1) {
            let a = atan2(pts[i].y - pts[i - 1].y, pts[i].x - pts[i - 1].x)
            let b = atan2(pts[i + 1].y - pts[i].y, pts[i + 1].x - pts[i].x)
            var d = b - a
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            total += abs(d)
        }
        return total
    }

    /// The whole point: the committed stroke is smoother than the live one.
    func test_finishedStrokeIsSmootherThanTheLiveOne() {
        let pts = stroke()
        let live = totalTurning(polyline(PenPath.smoothedPath(pts, finished: false)))
        let done = totalTurning(polyline(PenPath.smoothedPath(pts, finished: true)))
        XCTAssertLessThan(done, live,
                          "finished turning \(done) vs live \(live) — release must smooth further")
    }

    /// Finished strokes are fit as ONE span, so they need fewer segments than
    /// the chunked live fit. Fewer segments is fewer places to wobble, and no
    /// chunk seams.
    func test_finishedStrokeUsesFewerSegmentsThanTheLiveOne() {
        let pts = stroke()
        let live = PenPath.smoothedPath(pts, finished: false).elementCount
        let done = PenPath.smoothedPath(pts, finished: true).elementCount
        XCTAssertLessThan(done, live, "finished \(done) segments vs live \(live)")
    }

    /// Settling on release must not move the stroke somewhere else — it ends
    /// where the user lifted, in both profiles.
    func test_bothProfilesEndWhereTheUserLifted() {
        let pts = stroke()
        for finished in [true, false] {
            let path = PenPath.smoothedPath(pts, finished: finished)
            XCTAssertEqual(path.currentPoint.x, pts.last!.x, accuracy: 0.5,
                           "finished=\(finished)")
            XCTAssertEqual(path.currentPoint.y, pts.last!.y, accuracy: 0.5,
                           "finished=\(finished)")
        }
    }

    /// The settle must be a refinement, not a jump: the committed curve should
    /// stay close to the line the user watched being drawn.
    func test_theSettleOnReleaseIsSmallNotAJump() {
        let pts = stroke()
        let live = polyline(PenPath.smoothedPath(pts, finished: false))
        let done = polyline(PenPath.smoothedPath(pts, finished: true))
        // Compare at matched absolute arc lengths from the start.
        func sample(_ p: [CGPoint], _ d: CGFloat) -> CGPoint? {
            var cum: CGFloat = 0
            for i in 1..<p.count {
                let seg = hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y)
                if cum + seg >= d {
                    let u = seg > 0 ? (d - cum) / seg : 0
                    return CGPoint(x: p[i - 1].x + (p[i].x - p[i - 1].x) * u,
                                   y: p[i - 1].y + (p[i].y - p[i - 1].y) * u)
                }
                cum += seg
            }
            return nil
        }
        var worst: CGFloat = 0
        for d in stride(from: CGFloat(10), through: 300, by: 10) {
            guard let a = sample(live, d), let b = sample(done, d) else { break }
            worst = max(worst, hypot(a.x - b.x, a.y - b.y))
        }
        // Measured at ~5.8 units on this stroke. That IS the settle — the
        // committed profile smooths harder than the live one, which is the
        // whole point — so the gate is set to catch a JUMP (the fit landing
        // somewhere else entirely), not the refinement itself.
        XCTAssertLessThan(worst, 10.0,
                          "committed stroke moved \(worst) from the drawn one — that is a jump, not a settle")
    }

    /// The live profile keeps the properties that killed the jelly: chunked
    /// fitting and no pre-filter lag.
    func test_liveProfileIsConfiguredForStability() {
        XCTAssertEqual(PenPath.liveProfile.streamline, 1.0,
                       "pre-filter must stay off while drawing — it is what caused the tip lag")
        XCTAssertGreaterThan(PenPath.liveProfile.chunk, 0,
                             "live fitting must be chunked or the drawn line re-solves")
        XCTAssertEqual(PenPath.finishedProfile.chunk, 0,
                       "a finished stroke should be fit as one span — no seams")
    }
}
