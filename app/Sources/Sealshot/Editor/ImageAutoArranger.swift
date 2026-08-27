import CoreGraphics
import Foundation

/// Ordering strategy for Auto Arrange Images.
enum ArrangeOrder: Equatable {
    /// Pick the candidate ordering whose packed box is closest to 16:9.
    case auto
    /// Tallest → shortest (shelf packing is tightest this way).
    case largestFirst
    /// Shortest → tallest.
    case smallestFirst
}

/// Pure, no-scale rectangle packer. Lays fixed-size boxes into rows (shelf
/// packing) so the overall bounding box is roughly 16:9, at native size (nothing
/// is scaled). Returns one rect per input size, INDEX-ALIGNED to `sizes`, with the
/// bounding box normalized to origin (0,0). Rects never overlap.
enum ImageAutoArranger {
    static let targetAspect: CGFloat = 16.0 / 9.0

    static func arrange(sizes: [CGSize], order: ArrangeOrder, gap: CGFloat) -> [CGRect] {
        guard sizes.count > 1 else {
            return sizes.map { CGRect(origin: .zero, size: $0) }
        }
        let candidates: [[Int]]
        switch order {
        case .largestFirst:
            candidates = [sizes.indices.sorted { sizes[$0].height > sizes[$1].height }]
        case .smallestFirst:
            candidates = [sizes.indices.sorted { sizes[$0].height < sizes[$1].height }]
        case .auto:
            candidates = candidateOrders(sizes)
        }

        var best: [CGRect] = []
        var bestScore = CGFloat.greatestFiniteMagnitude
        var bestArea = CGFloat.greatestFiniteMagnitude
        for ord in candidates {
            let rects = pack(sizes: sizes, order: ord, gap: gap)
            let box = boundingBox(rects)
            let aspect = box.height > 0 ? box.width / box.height : targetAspect
            let score = abs(aspect - targetAspect)
            let area = box.width * box.height
            if score < bestScore - 0.0001
                || (abs(score - bestScore) <= 0.0001 && area < bestArea) {
                bestScore = score; bestArea = area; best = rects
            }
        }
        return normalize(best)
    }

    /// Candidate orderings tried for `.auto`.
    private static func candidateOrders(_ sizes: [CGSize]) -> [[Int]] {
        [
            sizes.indices.sorted { sizes[$0].height > sizes[$1].height },
            sizes.indices.sorted { sizes[$0].width * sizes[$0].height
                > sizes[$1].width * sizes[$1].height },
            sizes.indices.sorted { sizes[$0].width > sizes[$1].width },
            Array(sizes.indices),
        ]
    }

    /// Shelf-pack `order` at a target row width chosen so the box ≈ 16:9.
    /// Result is index-aligned to `sizes` (NOT normalized).
    private static func pack(sizes: [CGSize], order: [Int], gap: CGFloat) -> [CGRect] {
        let totalArea = sizes.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let maxWidth = sizes.map(\.width).max() ?? 0
        let slack: CGFloat = 1.15
        let targetW = max(maxWidth, (totalArea * slack * targetAspect).squareRoot())

        var out = [CGRect](repeating: .zero, count: sizes.count)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for i in order {
            let s = sizes[i]
            if x > 0 && x + s.width > targetW {   // wrap to a new row
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            out[i] = CGRect(x: x, y: y, width: s.width, height: s.height)
            x += s.width + gap
            rowHeight = max(rowHeight, s.height)
        }
        return out
    }

    private static func boundingBox(_ rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func normalize(_ rects: [CGRect]) -> [CGRect] {
        let box = boundingBox(rects)
        return rects.map { $0.offsetBy(dx: -box.minX, dy: -box.minY) }
    }
}
