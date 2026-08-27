import CoreGraphics
import Foundation

/// Freehand path simplification + anchor selection for the editable-polyline
/// pen tool. Pure — no UI, fully unit-testable.
enum PathSimplify {

    /// Max draggable anchors a committed pen stroke is reduced to.
    static let maxPenAnchors = 24

    /// Ramer–Douglas–Peucker: drop points within `epsilon` of the line through
    /// the segment's endpoints. First and last points are always preserved.
    static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }

        // Farthest point from the chord between the ends.
        let first = points.first!, last = points.last!
        var maxDist: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(points[i], from: first, to: last)
            if d > maxDist { maxDist = d; index = i }
        }

        if maxDist <= epsilon {
            return [first, last]
        }
        // Recurse on both halves and splice (drop the duplicated join point).
        let left = simplify(Array(points[0...index]), epsilon: epsilon)
        let right = simplify(Array(points[index..<points.count]), epsilon: epsilon)
        return left.dropLast() + right
    }

    /// Simplify a committed pen path to at most `maxPenAnchors` vertices.
    /// Coarsens epsilon until the result fits the cap.
    static func simplifiedPenPath(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var epsilon: CGFloat = 2.5
        var result = simplify(points, epsilon: epsilon)
        // Doubling epsilon ~halves detail each round; bounded so it always ends.
        var guardCount = 0
        while result.count > maxPenAnchors && guardCount < 40 {
            epsilon *= 1.6
            result = simplify(points, epsilon: epsilon)
            guardCount += 1
        }
        // Pathological fallback: if still over, keep endpoints + an even sample.
        if result.count > maxPenAnchors {
            result = anchorIndices(count: result.count, max: maxPenAnchors).map { result[$0] }
        }
        return result
    }

    /// Which vertex indices show a draggable dot: all when `count <= max`,
    /// otherwise an evenly-spaced subset that always includes the first and
    /// last index. Strictly increasing and unique.
    static func anchorIndices(count: Int, max: Int) -> [Int] {
        guard count > max else { return Array(0..<Swift.max(0, count)) }
        guard max >= 2 else { return count > 0 ? [0] : [] }
        var indices: [Int] = []
        for k in 0..<max {
            let i = Int((Double(k) * Double(count - 1) / Double(max - 1)).rounded())
            if indices.last != i { indices.append(i) }
        }
        return indices
    }

    private static func perpendicularDistance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-9 { return hypot(p.x - a.x, p.y - a.y) }
        // |cross(b-a, p-a)| / |b-a|
        let cross = abs(dx * (p.y - a.y) - dy * (p.x - a.x))
        return cross / sqrt(lenSq)
    }
}
