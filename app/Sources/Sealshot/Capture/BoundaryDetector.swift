import CoreGraphics

/// Detects axis-aligned UI boundaries (cards, panels, images, buttons) in a
/// frozen display image, so hovering can highlight the element under the
/// cursor. Pure: a `CGImage` in, rects (image pixel coordinates, top-left
/// origin) out. Runs once per freeze at reduced resolution, so hover lookups
/// cost nothing.
///
/// Method: downscale to grayscale → gradient edge maps → long horizontal /
/// vertical edge segments → pair top/bottom segments whose ends are connected
/// by sufficiently edgy columns → rects. `expand(from:)` is the local
/// fallback: scan outward from a point to the nearest strong edges.
enum BoundaryDetector {

    struct Params {
        var downscale = 4
        /// Min absolute gray gradient (0–255) that counts as an edge.
        /// Tuned UP (24 → 32 → 40): faint texture/gradient transitions
        /// produced low-confidence rects that made hover targets jumpy —
        /// only clearly drawn borders count.
        var edgeThreshold = 40
        /// Min segment length in downscaled px (~512pt at 4× on retina).
        /// Tuned up (16 → 24 → 32) for the same reason: short edge stubs
        /// pair into speculative rects.
        var minSegmentLength = 32
        /// Cap on horizontal segments considered for pairing (longest first).
        var maxSegments = 80
        /// Min rect side in downscaled px (24 ≈ 96 px ≈ 48 pt on retina) —
        /// small fragments aren't useful capture targets.
        var minRectSide: CGFloat = 24
        /// Fraction of a rect's vertical sides that must be edge pixels.
        /// Tuned up (0.55 → 0.7 → 0.8): a confident card/panel has
        /// near-complete vertical borders.
        var sideCoverage = 0.8
        /// Max distance (downscaled px) `expand` scans for an edge.
        var maxExpandScan = 500

        static let standard = Params()
    }

    // MARK: - Public API

    /// All detected boundary rects, image pixel coordinates, deduped.
    static func detect(in image: CGImage, params: Params = .standard) -> [CGRect] {
        guard let map = GrayMap(image: image, downscale: params.downscale) else { return [] }
        let horizontal = map.horizontalSegments(params: params)
        let vertical = map.verticalEdgeMap(threshold: params.edgeThreshold)
        var rects: [CGRect] = []

        for i in 0..<horizontal.count {
            for j in (i + 1)..<horizontal.count {
                let (top, bottom) = horizontal[i].y <= horizontal[j].y
                    ? (horizontal[i], horizontal[j]) : (horizontal[j], horizontal[i])
                guard let rect = Self.rect(
                    top: top, bottom: bottom, verticalEdges: vertical,
                    width: map.width, params: params) else { continue }
                rects.append(rect)
            }
        }

        // Per-axis true scale: integer-divided map dims make the effective
        // scale slightly ≠ downscale when the image size isn't divisible.
        let sx = CGFloat(image.width) / CGFloat(map.width)
        let sy = CGFloat(image.height) / CGFloat(map.height)
        let scaled = rects.map {
            CGRect(x: $0.minX * sx, y: $0.minY * sy,
                   width: $0.width * sx, height: $0.height * sy)
        }
        let deduped = dedupe(scaled)

        // Full-resolution refinement: coarse detection quantizes every edge
        // to the downscale grid (±2×downscale px ≈ 4pt on retina — visibly
        // off). Snap each side to the strongest nearby full-res gradient.
        guard !deduped.isEmpty,
              let full = GrayMap(image: image, downscale: 1) else { return deduped }
        let band = params.downscale * 2
        return deduped.map { refine($0, in: full, band: band) }
    }

    /// Local fallback: from `point` (image pixel coords), scan outward to the
    /// nearest strong edges in all four directions. Nil if any side is missing.
    static func expand(from point: CGPoint, in image: CGImage, params: Params = .standard) -> CGRect? {
        guard let map = GrayMap(image: image, downscale: params.downscale) else { return nil }
        let px = Int(point.x) / params.downscale
        let py = Int(point.y) / params.downscale
        guard px > 1, py > 1, px < map.width - 2, py < map.height - 2 else { return nil }

        let t = params.edgeThreshold
        let limit = params.maxExpandScan
        guard
            let left = map.scan(fromX: px, y: py, step: -1, limit: limit, threshold: t),
            let right = map.scan(fromX: px, y: py, step: 1, limit: limit, threshold: t),
            let top = map.scan(fromY: py, x: px, step: -1, limit: limit, threshold: t),
            let bottom = map.scan(fromY: py, x: px, step: 1, limit: limit, threshold: t)
        else { return nil }

        let scale = CGFloat(params.downscale)
        let rect = CGRect(x: CGFloat(left), y: CGFloat(top),
                          width: CGFloat(right - left), height: CGFloat(bottom - top))
        guard rect.width >= params.minRectSide, rect.height >= params.minRectSide else { return nil }
        return CGRect(x: rect.minX * scale, y: rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    // MARK: - Internals

    /// A horizontal run of strong horizontal-edge pixels.
    private struct HSegment {
        let y: Int
        let x0: Int
        let x1: Int
        var length: Int { x1 - x0 }
    }

    /// Downscaled grayscale pixel buffer with edge helpers.
    private struct GrayMap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(image: CGImage, downscale: Int) {
            let w = max(2, image.width / downscale)
            let h = max(2, image.height / downscale)
            guard let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }
            let rowBytes = ctx.bytesPerRow
            var buf = [UInt8](repeating: 0, count: w * h)
            let src = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)
            for row in 0..<h {
                for col in 0..<w { buf[row * w + col] = src[row * rowBytes + col] }
            }
            self.width = w
            self.height = h
            self.pixels = buf
        }

        // Buffer row 0 is the image's TOP row (CGBitmapContext memory layout),
        // so y here is already a top-left-origin image row — the same space the
        // detector reports rects in.
        func gray(_ x: Int, _ y: Int) -> Int { Int(pixels[y * width + x]) }

        /// |∂/∂y| at (x, y) — strong where a horizontal boundary line runs.
        func horizontalEdge(_ x: Int, _ y: Int, threshold: Int) -> Bool {
            abs(gray(x, y + 1) - gray(x, y - 1)) > threshold
        }

        /// |∂/∂x| at (x, y) — strong where a vertical boundary line runs.
        func verticalEdge(_ x: Int, _ y: Int, threshold: Int) -> Bool {
            abs(gray(x + 1, y) - gray(x - 1, y)) > threshold
        }

        /// Long horizontal edge runs (gap-merged), longest first, capped.
        func horizontalSegments(params: Params) -> [HSegment] {
            var segments: [HSegment] = []
            for y in 1..<(height - 1) {
                var runStart: Int?
                var gap = 0
                for x in 1..<(width - 1) {
                    if horizontalEdge(x, y, threshold: params.edgeThreshold) {
                        if runStart == nil { runStart = x }
                        gap = 0
                    } else if runStart != nil {
                        gap += 1
                        if gap > 2 {
                            let end = x - gap
                            if let start = runStart, end - start >= params.minSegmentLength {
                                segments.append(HSegment(y: y, x0: start, x1: end))
                            }
                            runStart = nil
                            gap = 0
                        }
                    }
                }
                if let start = runStart, (width - 2) - start >= params.minSegmentLength {
                    segments.append(HSegment(y: y, x0: start, x1: width - 2))
                }
            }
            return Array(segments.sorted { $0.length > $1.length }.prefix(params.maxSegments))
        }

        /// Per-pixel vertical-edge map (x-major lookup closure would be slow;
        /// expose coverage counting instead).
        func verticalEdgeMap(threshold: Int) -> (Int, Int) -> Bool {
            { x, y in
                guard x > 0, x < self.width - 1, y > 0, y < self.height - 1 else { return false }
                return self.verticalEdge(x, y, threshold: threshold)
            }
        }

        /// Scan along a row for the nearest vertical edge.
        func scan(fromX x: Int, y: Int, step: Int, limit: Int, threshold: Int) -> Int? {
            var cx = x + step
            var steps = 0
            while cx > 0 && cx < width - 1 && steps < limit {
                if verticalEdge(cx, y, threshold: threshold) { return cx }
                cx += step
                steps += 1
            }
            return nil
        }

        func scan(fromY y: Int, x: Int, step: Int, limit: Int, threshold: Int) -> Int? {
            var cy = y + step
            var steps = 0
            while cy > 0 && cy < height - 1 && steps < limit {
                if horizontalEdge(x, cy, threshold: threshold) { return cy }
                cy += step
                steps += 1
            }
            return nil
        }
    }

    /// Pair a top and bottom segment into a rect when their x-ranges overlap
    /// strongly and the connecting columns are sufficiently edgy.
    private static func rect(
        top: HSegment, bottom: HSegment,
        verticalEdges: (Int, Int) -> Bool,
        width: Int, params: Params
    ) -> CGRect? {
        let left = max(top.x0, bottom.x0)
        let right = min(top.x1, bottom.x1)
        let overlap = right - left
        guard overlap >= Int(params.minRectSide),
              CGFloat(overlap) >= 0.7 * CGFloat(min(top.length, bottom.length)),
              bottom.y - top.y >= Int(params.minRectSide) else { return nil }

        // Vertical sides: column ±1 tolerance, coverage over the rect height.
        func coverage(atColumn col: Int) -> Double {
            var hits = 0
            let total = bottom.y - top.y
            guard total > 0 else { return 0 }
            for y in top.y...bottom.y {
                if verticalEdges(col, y) || verticalEdges(col - 1, y) || verticalEdges(col + 1, y) {
                    hits += 1
                }
            }
            return Double(hits) / Double(total)
        }
        guard coverage(atColumn: left) >= params.sideCoverage,
              coverage(atColumn: right) >= params.sideCoverage else { return nil }

        return CGRect(x: CGFloat(left), y: CGFloat(top.y),
                      width: CGFloat(right - left), height: CGFloat(bottom.y - top.y))
    }

    /// Snap each side of a coarsely-detected rect to the strongest full-res
    /// gradient within ±`band` px. Sides fall back to the input when
    /// refinement would degenerate the rect. Cost: four narrow band scans per
    /// rect over a full-res gray map — negligible next to the freeze grab,
    /// and detect() already runs in a detached task.
    private static func refine(_ rect: CGRect, in map: GrayMap, band: Int) -> CGRect {
        let top = Int(rect.minY.rounded()), bottom = Int(rect.maxY.rounded())
        let left = Int(rect.minX.rounded()), right = Int(rect.maxX.rounded())
        // Sample only the interior span — corners can be off by `band` in
        // both axes, which would smear a side's gradient sum.
        let x0 = max(1, left + band), x1 = min(map.width - 2, right - band)
        let y0 = max(1, top + band), y1 = min(map.height - 2, bottom - band)
        guard x0 < x1, y0 < y1 else { return rect }

        func bestRow(near y: Int) -> Int {
            var best = y, bestScore = -1
            for r in max(1, y - band)...min(map.height - 2, y + band) {
                var score = 0
                var x = x0
                while x <= x1 {
                    score += abs(map.gray(x, r + 1) - map.gray(x, r - 1))
                    x += 2
                }
                if score > bestScore { bestScore = score; best = r }
            }
            return best
        }
        func bestColumn(near x: Int) -> Int {
            var best = x, bestScore = -1
            for c in max(1, x - band)...min(map.width - 2, x + band) {
                var score = 0
                var y = y0
                while y <= y1 {
                    score += abs(map.gray(c + 1, y) - map.gray(c - 1, y))
                    y += 2
                }
                if score > bestScore { bestScore = score; best = c }
            }
            return best
        }

        let rTop = bestRow(near: top), rBottom = bestRow(near: bottom)
        let rLeft = bestColumn(near: left), rRight = bestColumn(near: right)
        guard rBottom > rTop, rRight > rLeft else { return rect }
        return CGRect(x: CGFloat(rLeft), y: CGFloat(rTop),
                      width: CGFloat(rRight - rLeft), height: CGFloat(rBottom - rTop))
    }

    /// Drop near-duplicate rects (high overlap), keeping the first (larger
    /// pairing wins are equivalent here; stability is what matters).
    private static func dedupe(_ rects: [CGRect]) -> [CGRect] {
        var kept: [CGRect] = []
        for rect in rects.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            let isDuplicate = kept.contains { existing in
                let inter = existing.intersection(rect)
                guard !inter.isEmpty else { return false }
                let interArea = inter.width * inter.height
                let unionArea = existing.width * existing.height + rect.width * rect.height - interArea
                return unionArea > 0 && interArea / unionArea > 0.8
            }
            if !isDuplicate { kept.append(rect) }
        }
        return kept
    }
}
