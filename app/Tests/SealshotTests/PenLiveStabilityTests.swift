import XCTest
@testable import Sealshot

/// Two properties a freehand stroke must hold WHILE it is being drawn. Both
/// were violated at some point by the move from interpolation to fitting, and
/// both read to the user as the same word: "jelly".
///
/// 1. The drawn PREFIX must not move when a new sample arrives. Least squares
///    is global, so a single-span fit re-solves the whole stroke every event
///    and the line already on screen squirms. Chunked fitting confines that.
///
/// Both are asserted against the LIVE profile (`finished: false`). A finished
/// stroke is deliberately fit as one global span — it is not growing, so
/// nothing can disturb it — and would fail the prefix test by construction.
///
/// 2. The drawn TIP must stay under the pointer. Skipping the end pin on live
///    strokes was tried as a fix for (1) — it was not the cause, and it left
///    the ink trailing the cursor by several units, springing forward to catch
///    up. That is more rubbery than the thing it was meant to cure.
final class PenLiveStabilityTests: XCTestCase {

    /// Hand-like: a broad arc with tremor riding on it.
    private func stroke(_ n: Int) -> [CGPoint] {
        (0..<n).map { i -> CGPoint in
            let t = CGFloat(i) / 25
            return CGPoint(x: t * 90 + sin(CGFloat(i) * 2.7) * 0.8,
                           y: sin(t) * 70 + cos(CGFloat(i) * 3.1) * 0.8)
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

    /// Sample at ABSOLUTE arc lengths from the start.
    ///
    /// Not fractions — the stroke grows, so a fixed fraction names a different
    /// physical point at each step and reports ordinary growth as movement. An
    /// earlier version of this measurement made exactly that mistake and
    /// "found" 23 units of drift that did not exist.
    private func sampleAt(_ pts: [CGPoint], distances: [CGFloat]) -> [CGPoint]? {
        guard pts.count > 1 else { return nil }
        var cum: [CGFloat] = [0]
        for i in 1..<pts.count {
            cum.append(cum[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        guard let wanted = distances.last, cum[cum.count - 1] >= wanted else { return nil }
        return distances.map { target -> CGPoint in
            var j = 1
            while j < cum.count && cum[j] < target { j += 1 }
            if j >= cum.count { return pts[pts.count - 1] }
            let span = cum[j] - cum[j - 1]
            let u = span > 0 ? (target - cum[j - 1]) / span : 0
            return CGPoint(x: pts[j - 1].x + (pts[j].x - pts[j - 1].x) * u,
                           y: pts[j - 1].y + (pts[j].y - pts[j - 1].y) * u)
        }
    }

    /// Property 1. Fails if fitting is done as one global span.
    func test_theDrawnPrefixDoesNotMoveWhenASampleArrives() {
        let distances = stride(from: CGFloat(5), through: 120, by: 5).map { $0 }
        var worst: CGFloat = 0
        var compared = 0
        for n in 60..<160 {
            guard let a = sampleAt(polyline(PenPath.smoothedPath(stroke(n), finished: false)), distances: distances),
                  let b = sampleAt(polyline(PenPath.smoothedPath(stroke(n + 1), finished: false)), distances: distances)
            else { continue }
            for i in 0..<a.count {
                worst = max(worst, hypot(a[i].x - b[i].x, a[i].y - b[i].y))
            }
            compared += 1
        }
        XCTAssertGreaterThan(compared, 50, "need enough growth steps to be meaningful")
        XCTAssertLessThan(worst, 0.5, "drawn prefix moved by \(worst) — that is the jelly")
    }

    /// Property 2. Fails if the end pin is skipped while drawing: measured at
    /// 6.24 units mean lag when it was.
    func test_theDrawnTipStaysUnderThePointer() {
        var worst: CGFloat = 0
        for n in 60..<160 {
            let pts = stroke(n)
            guard let cursor = pts.last else { continue }
            let path = PenPath.smoothedPath(pts, finished: false)
            worst = max(worst, hypot(path.currentPoint.x - cursor.x,
                                     path.currentPoint.y - cursor.y))
        }
        XCTAssertLessThan(worst, 0.01,
                          "ink trailed the pointer by \(worst) — it will spring forward to catch up")
    }

    /// Report the ACTUAL worst prefix movement, with no threshold, so a
    /// sub-0.5 shift that the gate tolerates is still visible.
    func test_reportExactWorstPrefixMovement() {
        let distances = stride(from: CGFloat(5), through: 100, by: 2.5).map { $0 }
        var worst: CGFloat = 0
        var worstN = 0
        for n in 40..<200 {
            guard let a = sampleAt(polyline(PenPath.smoothedPath(stroke(n), finished: false)), distances: distances),
                  let b = sampleAt(polyline(PenPath.smoothedPath(stroke(n + 1), finished: false)), distances: distances)
            else { continue }
            for i in 0..<a.count {
                let d = hypot(a[i].x - b[i].x, a[i].y - b[i].y)
                if d > worst { worst = d; worstN = n }
            }
        }
        print("\n>>> WORST PREFIX MOVEMENT: \(String(format: "%.4f", worst)) units (at n=\(worstN))\n")
        XCTAssertGreaterThanOrEqual(worst, 0)
    }

    /// Measure movement BEHIND THE TIP — the region both earlier measurements
    /// systematically excluded. The end-pin ramp corrects the last N points
    /// relative to the tip, so that window slides forward as the stroke grows
    /// and points revert as they fall out of it.
    func test_reportMovementJustBehindTheTip() {
        // Distances measured BACK from the end of the shorter curve.
        let backOffsets: [CGFloat] = [2, 4, 6, 8, 10, 14, 18, 24, 30, 40, 60]
        var worst: CGFloat = 0
        var worstOffset: CGFloat = 0
        var perOffset: [CGFloat: CGFloat] = [:]
        for n in 60..<200 {
            let a = polyline(PenPath.smoothedPath(stroke(n), finished: false))
            let b = polyline(PenPath.smoothedPath(stroke(n + 1), finished: false))
            guard a.count > 2, b.count > 2 else { continue }
            let lenA = arcLength(a), lenB = arcLength(b)
            let shorter = min(lenA, lenB)
            for off in backOffsets where shorter - off > 5 {
                // Same ABSOLUTE distance from the start in both curves, chosen
                // relative to the shorter curve's tip.
                let target = shorter - off
                guard let pa = sampleAt(a, distances: [target])?.first,
                      let pb = sampleAt(b, distances: [target])?.first else { continue }
                let d = hypot(pa.x - pb.x, pa.y - pb.y)
                perOffset[off] = max(perOffset[off] ?? 0, d)
                if d > worst { worst = d; worstOffset = off }
            }
        }
        var profile = ""
        for off in backOffsets {
            profile += String(format: "    %4.0f units back : %.4f\n", off, perOffset[off] ?? 0)
        }
        print("\n>>> MOVEMENT PROFILE BEHIND THE TIP\n\(profile)>>> worst \(String(format: "%.4f", worst)) at \(String(format: "%.0f", worstOffset))\n")
        XCTAssertGreaterThanOrEqual(worst, 0)
    }

    private func arcLength(_ pts: [CGPoint]) -> CGFloat {
        var t: CGFloat = 0
        for i in 1..<pts.count { t += hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y) }
        return t
    }

    /// A committed stroke ends exactly where the user lifted.
    func test_strokeEndsExactlyWhereTheUserLifted() {
        let pts = stroke(220)
        let path = PenPath.smoothedPath(pts)
        XCTAssertEqual(path.currentPoint.x, pts.last!.x, accuracy: 0.5)
        XCTAssertEqual(path.currentPoint.y, pts.last!.y, accuracy: 0.5)
    }
}
