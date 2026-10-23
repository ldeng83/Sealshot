import CoreGraphics

extension RecognizedTextLayout {

    /// Reading order that keeps each text block together: lines are grouped
    /// into blocks (a column, a sidebar, a paragraph), blocks are read top-first
    /// then left-to-right, and lines within a block top-to-bottom.
    ///
    /// Selection and copy walk `lines` by index, so a pure row order — every
    /// line on the image sorted by its row — made a drag down one column also
    /// take the lines of every other column on the rows in between, and copied
    /// text came out interleaved.
    ///
    /// Two lines share a block when they are stacked within about a line of
    /// each other, overlap horizontally, and are of similar text height — or
    /// sit on the same row with only a small gap, which keeps a table or a
    /// label beside its value in row order instead of reading it column by
    /// column. Coordinates are normalized, top-left origin.
    static func blockReadingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        guard lines.count > 1 else { return lines }
        var parent = Array(lines.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in lines.indices {
            for j in (i + 1)..<lines.count where sameBlock(lines[i].box, lines[j].box) {
                parent[find(i)] = find(j)
            }
        }
        var blocks: [Int: [RecognizedLine]] = [:]
        for i in lines.indices { blocks[find(i), default: []].append(lines[i]) }

        // Snap tops to a 1%-of-height grid so items on the same visual row share
        // a key — a valid strict-weak ordering, unlike a raw tolerance band.
        func rowKey(_ y: CGFloat) -> CGFloat { (y / 0.01).rounded() * 0.01 }
        func rowOrder(_ a: CGRect, _ b: CGRect) -> Bool {
            let ka = rowKey(a.minY), kb = rowKey(b.minY)
            return ka != kb ? ka < kb : a.minX < b.minX
        }
        let ordered = blocks.values.map { $0.sorted { rowOrder($0.box, $1.box) } }
        return ordered
            .sorted { rowOrder(bounds($0), bounds($1)) }
            .flatMap { $0 }
    }

    private static func bounds(_ block: [RecognizedLine]) -> CGRect {
        block.reduce(CGRect.null) { $0.union($1.box) }
    }

    private static func sameBlock(_ a: CGRect, _ b: CGRect) -> Bool {
        let hMin = min(a.height, b.height), hMax = max(a.height, b.height)
        guard hMin > 0, hMax / hMin <= 1.5 else { return false }
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        if overlapY > hMin * 0.5 {
            // Same row: one block only across a small horizontal gap.
            let gapX = max(a.minX, b.minX) - min(a.maxX, b.maxX)
            return gapX <= hMax * 1.5
        }
        // Stacked: within about a line of each other, sharing some x-range.
        let gapY = max(a.minY, b.minY) - min(a.maxY, b.maxY)
        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return gapY <= hMax * 1.0 && overlapX > 0
    }
}
