import XCTest
@testable import Sealshot

/// Pure-geometry tests for the dense-table column-gutter detector (Live Text
/// issue B: Vision reads two tightly-spaced cells as one line when a tile crop
/// straddles a column boundary). All boxes are normalized [0,1] top-left,
/// mirroring `RecognizedLine.box`. Detection uses only line-level boxes from
/// the correctly-read rows — no `boundingBox(for:)` word geometry, which this
/// pipeline has found unreliable.
final class ColumnGutterSplitterTests: XCTestCase {

    /// A dense-table line box: rows stack 0.03 apart, line height 0.015.
    private func row(_ i: Int, x: CGFloat, w: CGFloat, h: CGFloat = 0.015) -> CGRect {
        CGRect(x: x, y: 0.1 + CGFloat(i) * 0.03, width: w, height: h)
    }
    /// Text sized so width/count gives a plausible dense-table char width
    /// (~0.006 normalized) for the given box width.
    private func text(for width: CGFloat) -> String {
        String(repeating: "x", count: max(1, Int(width / 0.006)))
    }

    /// Two-column table, five clean rows, one cross-column merged read: only
    /// the merged row is repaired, split at the gutter between the columns.
    func test_twoColumnTable_splitsOnlyTheMergedRow() {
        var boxes: [CGRect] = []
        var texts: [String] = []
        for i in 0..<6 where i != 2 {
            boxes.append(row(i, x: 0.10, w: 0.17)); texts.append(text(for: 0.17))
            boxes.append(row(i, x: 0.40, w: 0.18)); texts.append(text(for: 0.18))
        }
        let mergedIndex = boxes.count
        boxes.append(row(2, x: 0.10, w: 0.48))          // spans 0.10 … 0.58
        texts.append(text(for: 0.48))

        let repairs = columnGutterRepairs(boxes: boxes, texts: texts)
        XCTAssertEqual(repairs.count, 1, "only the merged row is repaired")
        guard case .reread(let subBoxes)? = repairs[mergedIndex] else {
            return XCTFail("merged row should be re-read, got \(String(describing: repairs[mergedIndex]))")
        }
        XCTAssertEqual(subBoxes.count, 2)
        // LOSSLESS split: the pieces tile the whole line (no interior excluded)
        // and the cut falls inside the gutter. Clean rows put it at [0.27, 0.40].
        XCTAssertEqual(subBoxes[0].minX, boxes[mergedIndex].minX, accuracy: 0.0001)
        XCTAssertEqual(subBoxes[1].maxX, boxes[mergedIndex].maxX, accuracy: 0.0001)
        XCTAssertEqual(subBoxes[0].maxX, subBoxes[1].minX, accuracy: 0.0001,
                       "segments must be contiguous — a gap would lose text")
        XCTAssertGreaterThanOrEqual(subBoxes[0].maxX, 0.27 - 0.001)
        XCTAssertLessThanOrEqual(subBoxes[1].minX, 0.40 + 0.001)
        // Sub-boxes keep the merged line's vertical extent.
        XCTAssertEqual(subBoxes[0].minY, boxes[mergedIndex].minY, accuracy: 0.0001)
        XCTAssertEqual(subBoxes[1].height, boxes[mergedIndex].height, accuracy: 0.0001)
    }

    /// The failure that killed per-line splitting: cell widths vary per row
    /// (short + long values) so per-row gaps disagree — but the INTERSECTION
    /// across rows is still the true gutter.
    func test_variableCellWidths_intersectionStillFindsGutter() {
        var boxes: [CGRect] = []
        var texts: [String] = []
        let leftWidths: [CGFloat] = [0.08, 0.19, 0.12, 0.16, 0.10]   // right edges vary 0.18…0.29
        for (i, w) in leftWidths.enumerated() {
            boxes.append(row(i, x: 0.10, w: w)); texts.append(text(for: w))
            boxes.append(row(i, x: 0.33, w: 0.20)); texts.append(text(for: 0.20))
        }
        let mergedIndex = boxes.count
        boxes.append(row(5, x: 0.10, w: 0.40))
        texts.append(text(for: 0.40))

        guard case .reread(let subBoxes)? = columnGutterRepairs(boxes: boxes, texts: texts)[mergedIndex] else {
            return XCTFail("merged row not repaired")
        }
        XCTAssertEqual(subBoxes.count, 2)
        // Band = [widest left edge, right column start] = [0.29, 0.33]; the
        // lossless cut lands inside it and the pieces tile the line.
        XCTAssertEqual(subBoxes[0].maxX, subBoxes[1].minX, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(subBoxes[0].maxX, 0.29 - 0.001)
        XCTAssertLessThanOrEqual(subBoxes[1].minX, 0.33 + 0.001)
    }

    /// A merged read that COEXISTS with the correct per-cell reads on the same
    /// row (tile overlap: the straddling tile merged, a neighbour tile read the
    /// cells separately, and dedup keeps all three) is redundant — drop it
    /// instead of re-reading.
    func test_mergedReadRedundantWithCellReads_isDropped() {
        var boxes: [CGRect] = []
        var texts: [String] = []
        for i in 0..<6 {
            boxes.append(row(i, x: 0.10, w: 0.17)); texts.append(text(for: 0.17))
            boxes.append(row(i, x: 0.40, w: 0.18)); texts.append(text(for: 0.18))
        }
        let mergedIndex = boxes.count
        boxes.append(row(2, x: 0.10, w: 0.48))          // duplicates row 2's cells
        texts.append(text(for: 0.48))

        let repairs = columnGutterRepairs(boxes: boxes, texts: texts)
        XCTAssertEqual(repairs[mergedIndex], .drop,
                       "content already present as separate cell reads")
        XCTAssertEqual(repairs.count, 1)
    }

    /// Prose (full-width lines, no aligned gaps) must not split, even when a
    /// couple of short two-word lines have gaps at random unaligned positions
    /// (support below the vote threshold).
    func test_prose_noFalseSplit() {
        var boxes: [CGRect] = []
        var texts: [String] = []
        for i in 0..<6 {
            boxes.append(row(i, x: 0.10, w: 0.62)); texts.append(text(for: 0.62))
        }
        boxes.append(row(6, x: 0.10, w: 0.10)); texts.append(text(for: 0.10))
        boxes.append(row(6, x: 0.30, w: 0.15)); texts.append(text(for: 0.15))
        boxes.append(row(7, x: 0.10, w: 0.20)); texts.append(text(for: 0.20))
        boxes.append(row(7, x: 0.45, w: 0.15)); texts.append(text(for: 0.15))

        XCTAssertTrue(columnGutterRepairs(boxes: boxes, texts: texts).isEmpty)
    }

    /// A heading legitimately spans the columns beneath it — tall lines are
    /// exempt (the title-stitch owns them), so it is never repaired.
    func test_headingSpanningColumns_notSplit() {
        var boxes: [CGRect] = []
        var texts: [String] = []
        boxes.append(CGRect(x: 0.10, y: 0.07, width: 0.50, height: 0.035))  // heading
        texts.append("Stabilize the Core, Then Accelerate")
        for i in 0..<5 {
            boxes.append(row(i, x: 0.10, w: 0.17)); texts.append(text(for: 0.17))
            boxes.append(row(i, x: 0.40, w: 0.18)); texts.append(text(for: 0.18))
        }
        XCTAssertTrue(columnGutterRepairs(boxes: boxes, texts: texts).isEmpty,
                      "tall heading must not be split by the table below it")
    }

    /// Three columns; the merged read spans both gutters → three pieces.
    func test_threeColumns_spanningLineSplitsIntoThree() {
        var boxes: [CGRect] = []
        var texts: [String] = []
        for i in 0..<5 {
            boxes.append(row(i, x: 0.05, w: 0.14)); texts.append(text(for: 0.14))
            boxes.append(row(i, x: 0.30, w: 0.14)); texts.append(text(for: 0.14))
            boxes.append(row(i, x: 0.55, w: 0.14)); texts.append(text(for: 0.14))
        }
        let mergedIndex = boxes.count
        boxes.append(row(5, x: 0.05, w: 0.64))
        texts.append(text(for: 0.64))

        guard case .reread(let subBoxes)? = columnGutterRepairs(boxes: boxes, texts: texts)[mergedIndex] else {
            return XCTFail("merged row not repaired")
        }
        XCTAssertEqual(subBoxes.count, 3)
        // Contiguous lossless tiling across both cuts.
        XCTAssertEqual(subBoxes[0].maxX, subBoxes[1].minX, accuracy: 0.0001)
        XCTAssertEqual(subBoxes[1].maxX, subBoxes[2].minX, accuracy: 0.0001)
        XCTAssertEqual(subBoxes[0].minX, boxes[mergedIndex].minX, accuracy: 0.0001)
        XCTAssertEqual(subBoxes[2].maxX, boxes[mergedIndex].maxX, accuracy: 0.0001)
    }

    /// When most rows cross the candidate band (an accidentally aligned gap in
    /// otherwise full-width text), the band is not a gutter — reject.
    func test_crossingVeto_rejectsAccidentallyAlignedGaps() {
        var boxes: [CGRect] = []
        var texts: [String] = []
        // Three rows with an aligned gap at [0.30, 0.36] (support 3)…
        for i in 0..<3 {
            boxes.append(row(i, x: 0.10, w: 0.20)); texts.append(text(for: 0.20))
            boxes.append(row(i, x: 0.36, w: 0.20)); texts.append(text(for: 0.20))
        }
        // …but five more rows of full-width text crossing that band.
        for i in 3..<8 {
            boxes.append(row(i, x: 0.10, w: 0.46)); texts.append(text(for: 0.46))
        }
        XCTAssertTrue(columnGutterRepairs(boxes: boxes, texts: texts).isEmpty,
                      "a band most rows cross is not a gutter")
    }

    /// A band anchored on a tile seam is fragment residue (truncated reads
    /// start/end exactly at seams), not a gutter — rejected even with full
    /// row support. The same table with no seams nearby still splits.
    func test_bandAnchoredOnTileSeam_rejected() {
        var boxes: [CGRect] = []
        var texts: [String] = []
        for i in 0..<6 where i != 2 {
            boxes.append(row(i, x: 0.10, w: 0.17)); texts.append(text(for: 0.17))
            boxes.append(row(i, x: 0.40, w: 0.18)); texts.append(text(for: 0.18))
        }
        let mergedIndex = boxes.count
        boxes.append(row(2, x: 0.10, w: 0.48))
        texts.append(text(for: 0.48))

        // Band is [0.27, 0.40]: a seam at either edge kills it…
        XCTAssertTrue(columnGutterRepairs(boxes: boxes, texts: texts, seams: [0.27]).isEmpty)
        XCTAssertTrue(columnGutterRepairs(boxes: boxes, texts: texts, seams: [0.40]).isEmpty)
        // …a seam elsewhere leaves it intact.
        XCTAssertNotNil(columnGutterRepairs(boxes: boxes, texts: texts, seams: [0.70])[mergedIndex])
    }

    /// Too few rows for a vote → nothing splits (no table evidence).
    func test_tooFewRows_noSplit() {
        let boxes = [row(0, x: 0.10, w: 0.15), row(0, x: 0.40, w: 0.15),
                     row(1, x: 0.10, w: 0.48)]
        let texts = boxes.map { text(for: $0.width) }
        XCTAssertTrue(columnGutterRepairs(boxes: boxes, texts: texts).isEmpty)
    }
}
