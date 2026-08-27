import CoreGraphics

enum TableReconstructor {
    static func clusterRows(_ tokens: [LayoutToken], tolerance: CGFloat) -> [[LayoutToken]] {
        let sorted = tokens.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[LayoutToken]] = []
        for t in sorted {
            if let ref = rows.last?.first, abs(ref.rect.midY - t.rect.midY) <= tolerance {
                rows[rows.count - 1].append(t)
            } else {
                rows.append([t])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    // Returns (midpoint, width) pairs for each vertical band of width >= minGap
    // that no token's x-span overlaps.
    private static func detectColumnGutterDetails(_ tokens: [LayoutToken], minGap: CGFloat) -> [(mid: CGFloat, width: CGFloat)] {
        guard !tokens.isEmpty else { return [] }

        // Collect all x-interval endpoints from token rects
        struct Event {
            let x: CGFloat
            let isStart: Bool
        }
        var events: [Event] = []
        for t in tokens {
            events.append(Event(x: t.rect.minX, isStart: true))
            events.append(Event(x: t.rect.maxX, isStart: false))
        }
        // Sort: process ends before starts at the same x so a zero-width gap between
        // adjacent tokens is not treated as a gutter.
        events.sort {
            if $0.x != $1.x { return $0.x < $1.x }
            // ends first: isStart false < true
            return !$0.isStart && $1.isStart
        }

        var result: [(mid: CGFloat, width: CGFloat)] = []
        var depth = 0
        var gapStart: CGFloat? = nil

        for e in events {
            if e.isStart {
                if depth == 0, let gs = gapStart {
                    let width = e.x - gs
                    if width >= minGap {
                        result.append((mid: gs + width / 2, width: width))
                    }
                    gapStart = nil
                }
                depth += 1
            } else {
                depth -= 1
                if depth == 0 {
                    gapStart = e.x
                }
            }
        }
        return result
    }

    /// Sorted x-positions of vertical whitespace bands (width >= minGap) that no token spans.
    static func detectColumnGutters(_ tokens: [LayoutToken], minGap: CGFloat) -> [CGFloat] {
        detectColumnGutterDetails(tokens, minGap: minGap)
            .map(\.mid)
            .sorted()
    }

    /// Column cut positions derived from the distribution of token x-centers,
    /// robust to rows that span a would-be gutter (unlike empty-band detection,
    /// which fails on real documents where a title or stray token fills the gap).
    /// Sort the token `midX` values; start a new column cluster whenever the gap
    /// to the previous center is >= `minSeparation`; the cut between adjacent
    /// clusters is the midpoint of that gap. Returns sorted interior cuts
    /// (N clusters → N-1 cuts).
    static func columnBoundaries(_ tokens: [LayoutToken], minSeparation: CGFloat) -> [CGFloat] {
        let centers = tokens.map(\.rect.midX).sorted()
        guard centers.count > 1 else { return [] }
        var boundaries: [CGFloat] = []
        for i in 1..<centers.count where centers[i] - centers[i - 1] >= minSeparation {
            boundaries.append((centers[i] + centers[i - 1]) / 2)
        }
        return boundaries
    }

    /// Assigns each token in a row to a column and returns one string per column.
    ///
    /// `boundaries` are sorted interior x-cut positions in normalised [0, 1] coordinates,
    /// producing N+1 columns from N cuts.  Column i spans [cuts[i-1], cuts[i]) where
    /// cuts[-1] = 0 (implicit) and cuts[N] = 1 (implicit).  A token whose `rect.midX`
    /// falls in that half-open interval belongs to column i.  Multiple tokens in the same
    /// column are joined with a single space in left-to-right (ascending midX) order.
    /// Empty columns produce an empty string.
    static func assignColumns(_ row: [LayoutToken], boundaries: [CGFloat]) -> [String] {
        let columnCount = boundaries.count + 1
        // Build column buckets: each bucket is an array of (midX, text) pairs.
        var buckets: [[(midX: CGFloat, text: String)]] = Array(repeating: [], count: columnCount)

        for token in row {
            let midX = token.rect.midX
            // Find which column interval [cuts[i-1], cuts[i]) contains midX.
            var col = columnCount - 1   // default to last column
            for (i, cut) in boundaries.enumerated() {
                if midX < cut {
                    col = i
                    break
                }
            }
            buckets[col].append((midX: midX, text: token.text))
        }

        return buckets.map { entries in
            entries.sorted { $0.midX < $1.midX }.map(\.text).joined(separator: " ")
        }
    }

    /// Produces a reading-order transcript by clustering tokens into rows, sorting each row
    /// left-to-right, joining tokens within a row with a single space, and joining rows with "\n".
    static func geometryOrderedTranscript(_ tokens: [LayoutToken], tolerance: CGFloat) -> String {
        let rows = clusterRows(tokens, tolerance: tolerance)
        return rows.map { row in
            row.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// Orchestrates Tasks 1–3 to produce a `StructuredTable` for each qualifying region.
    ///
    /// Algorithm:
    /// 1. Split tokens into independent vertical-band regions via `splitRegions`.
    /// 2. For each region: cluster into rows, detect in-region column gutters, assign columns.
    /// 3. Treat the first row as headers and remaining rows as data rows.
    /// 4. Drop any region that yields < 2 rows (need headers + ≥1 data row) or < 2 columns (prose).
    static func buildTables(_ tokens: [LayoutToken], tolerance: CGFloat,
                            minGap: CGFloat, columnSeparation: CGFloat) -> [StructuredTable] {
        let regions = splitRegions(tokens, minGap: minGap)
        var result: [StructuredTable] = []

        for region in regions {
            let rows = clusterRows(region, tolerance: tolerance)
            guard rows.count >= 2 else { continue }

            // Columns come from the x-center distribution (not empty bands), so a
            // spanning title row no longer suppresses the whole table.
            let boundaries = columnBoundaries(region, minSeparation: columnSeparation)
            guard boundaries.count >= 1 else { continue }   // < 2 columns → prose, skip

            let grid = rows.map { assignColumns($0, boundaries: boundaries) }
            let headers  = grid[0]
            let dataRows = Array(grid.dropFirst())

            result.append(StructuredTable(headers: headers, rows: dataRows))
        }

        return result
    }

    /// Partition tokens into independent table regions by the widest gutter (v1: two-region split).
    /// Returns one region when no gutter of minGap width exists.
    static func splitRegions(_ tokens: [LayoutToken], minGap: CGFloat) -> [[LayoutToken]] {
        guard !tokens.isEmpty else { return [] }
        let gutters = detectColumnGutterDetails(tokens, minGap: minGap)
        guard let widest = gutters.max(by: { $0.width < $1.width }) else {
            return [tokens]
        }
        let mid = widest.mid
        let left  = tokens.filter { $0.rect.midX <= mid }
        let right = tokens.filter { $0.rect.midX >  mid }
        var regions: [[LayoutToken]] = []
        if !left.isEmpty  { regions.append(left)  }
        if !right.isEmpty { regions.append(right) }
        return regions.isEmpty ? [tokens] : regions
    }

    /// Build one `StructuredTable` per detected box by running the existing
    /// per-region logic on the tokens whose center falls inside the box
    /// (expanded by `inset`). Coordinates stay in full-image normalized space,
    /// so `tolerance`/`columnSeparation` carry the same meaning as in `buildTables`.
    /// Boxes yielding < 2 rows or < 2 columns are dropped (same rule as geometry).
    static func buildTables(inBoxes boxes: [CGRect], tokens: [LayoutToken],
                            tolerance: CGFloat, columnSeparation: CGFloat,
                            inset: CGFloat) -> [StructuredTable] {
        var result: [StructuredTable] = []
        for box in boxes {
            let region = box.insetBy(dx: -inset, dy: -inset)
            let inside = tokens.filter {
                region.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY))
            }
            let rows = clusterRows(inside, tolerance: tolerance)
            guard rows.count >= 2 else { continue }
            let boundaries = columnBoundaries(inside, minSeparation: columnSeparation)
            guard boundaries.count >= 1 else { continue }
            let grid = rows.map { assignColumns($0, boundaries: boundaries) }
            result.append(StructuredTable(headers: grid[0], rows: Array(grid.dropFirst())))
        }
        return result
    }
}
