import CoreGraphics
import Foundation

/// Dense-table cross-column repair (Live Text issue B).
///
/// `VNRecognizeTextRequest` reads two tightly-spaced table cells as ONE line
/// when the recognized crop straddles the column boundary — a documented
/// Vision behavior, made frequent by tiled OCR (a tile seam can land inside a
/// table). Per-line whitespace splitting is provably ambiguous ("short value +
/// long value look merged"), so detection here is GLOBAL and row-voted:
///
///   • The merge is intermittent — most visual rows of the same table are
///     correctly read as separate lines per cell. Those rows' line boxes
///     define per-row clear gaps, and the INTERSECTION of aligned gaps across
///     rows is the column gutter. One vote per row, so a wordy row carries no
///     extra weight, and cell widths may vary freely.
///   • Word-range geometry (`boundingBox(for:)`) is deliberately NOT used for
///     GUTTER INFERENCE — even though TextRecognizer opportunistically accepts
///     validated token boxes for highlights, a bad range must never split rows.
///
/// A line that fully spans a voted gutter is repaired one of two ways
/// (decided here, applied by the caller):
///   • `.drop` — the straddling tile's merged read coexists with the correct
///     per-cell reads from a neighbouring tile (dedup keeps all: the boxes
///     don't meet its IoU bar). The merged line is redundant; remove it.
///   • `.reread(subBoxes:)` — split the line's box at the gutter band(s) and
///     re-OCR each side from the full-res source (the caller owns the OCR).
///     The recognized STRING is never split heuristically: a merged read's
///     text is contaminated at recognition time (gutter-adjacent tokens,
///     punctuation, ordering), so only a fresh column-scoped read is trusted.
enum GutterRepair: Equatable {
    /// The spanning line's content is already present as separate same-row
    /// cell reads — remove the line outright.
    case drop
    /// Re-OCR these sub-regions (normalized, left→right) and replace the
    /// line with the results.
    case reread(subBoxes: [CGRect])
}

// MARK: - Tuning

/// Lines taller than this multiple of the region's median line height are
/// headings — they legitimately span columns (and the height-gated title
/// stitch owns them), so they are never candidates and never veto a gutter.
private let gutterHeightGateFactor: CGFloat = 1.5
/// Vertical half-window (× median line height) around a candidate within
/// which rows contribute gutter evidence — a table's rows are packed, so a
/// handful of line-heights covers plenty of voting rows without dragging in
/// unrelated layout above/below.
private let gutterNeighborhoodFactor: CGFloat = 6.0
/// A gutter needs at least this many distinct supporting rows…
private let gutterMinSupportRows = 3
/// …and supporters must dominate: supporters / (supporters + crossers) must
/// reach this fraction, or the "gutter" is just an accidentally aligned gap
/// in text that mostly flows across it. 0.6 proved too permissive at the
/// neighborhood-window margin (3 supporters vs 2 crossers slipped through);
/// a real table's gutter is clear in nearly every row, so demand 70%.
private let gutterMinSupportFraction: CGFloat = 0.7
/// Minimum gutter width as a multiple of the median character width —
/// ordinary inter-word spaces are ~1 char wide, column gutters are wider.
private let gutterMinWidthCharFactor: CGFloat = 1.5
/// Absolute floor for the gutter width (normalized) so a degenerate char-width
/// estimate can't accept hairline gaps.
private let gutterMinWidthFloor: CGFloat = 0.002
/// Two lines share a visual row when they overlap vertically by more than
/// this fraction of the shorter line's height.
private let rowOverlapFraction: CGFloat = 0.5
/// A spanning line is `.drop`-redundant when every one of its segments is
/// covered by a same-row sibling by at least this fraction of the segment.
private let redundantCoverageFraction: CGFloat = 0.6
/// A voted band whose EDGE lies within this distance of a tile seam is
/// rejected: seam-truncated fragments (reads a tile edge cut, kept when no
/// fuller read exists to absorb them into) start/end exactly at seams, so
/// their gaps stack up there row after row and fake a gutter. A true gutter
/// that happens to coincide with a seam is skipped too — degrading to
/// Vision's stock behavior, never worse.
private let gutterSeamEdgeTolerance: CGFloat = 0.008

// MARK: - Detection

/// Decide repairs for lines that span voted column gutters. `boxes`/`texts`
/// are the recognized lines (normalized [0,1] top-left boxes and their
/// strings — texts are used only to estimate character width). `seams` are
/// the interior tile-edge x positions (normalized) of the tiled OCR pass;
/// bands anchored on a seam are rejected (see `gutterSeamEdgeTolerance`).
/// Returns an empty map when there is no table evidence; indices not in the
/// map are untouched.
func columnGutterRepairs(boxes: [CGRect], texts: [String],
                         seams: [CGFloat] = []) -> [Int: GutterRepair] {
    let n = boxes.count
    guard n > 2 * gutterMinSupportRows else { return [:] }

    let medianHeight = median(boxes.map(\.height))
    guard medianHeight > 0 else { return [:] }
    let heightGate = medianHeight * gutterHeightGateFactor

    // Median character width over body-height lines → minimum gutter width.
    let charWidths = (0..<n).compactMap { i -> CGFloat? in
        guard boxes[i].height <= heightGate, !texts[i].isEmpty else { return nil }
        return boxes[i].width / CGFloat(texts[i].count)
    }
    guard let medianCharWidth = charWidths.isEmpty ? nil : median(charWidths) else { return [:] }
    let minGutterWidth = max(medianCharWidth * gutterMinWidthCharFactor, gutterMinWidthFloor)

    let rows = visualRows(boxes)
    let rowOf = rowIndexByLine(rows, count: n)

    var repairs: [Int: GutterRepair] = [:]
    for i in 0..<n {
        let line = boxes[i]
        guard line.height <= heightGate else { continue }   // headings exempt

        let bands = acceptedBands(spanning: line, candidate: i, boxes: boxes,
                                  rows: rows, rowOf: rowOf,
                                  heightGate: heightGate,
                                  neighborhood: medianHeight * gutterNeighborhoodFactor,
                                  minGutterWidth: minGutterWidth, seams: seams)
        guard !bands.isEmpty else { continue }

        let segments = subBoxes(of: line, splitAt: bands, minWidth: minGutterWidth)
        guard segments.count >= 2 else { continue }

        if isRedundant(line: i, segments: segments, boxes: boxes, rows: rows, rowOf: rowOf) {
            repairs[i] = .drop
        } else {
            repairs[i] = .reread(subBoxes: segments)
        }
    }
    return repairs
}

// MARK: - Gutter voting

/// Gutter bands that `line` fully spans, voted by the rows in its vertical
/// neighborhood. Sorted left→right, non-overlapping.
private func acceptedBands(spanning line: CGRect, candidate: Int, boxes: [CGRect],
                           rows: [[Int]], rowOf: [Int],
                           heightGate: CGFloat, neighborhood: CGFloat,
                           minGutterWidth: CGFloat,
                           seams: [CGFloat]) -> [ClosedRange<CGFloat>] {
    // Rows contributing evidence: any row with a member vertically near the
    // candidate. The candidate's own row still participates (its OTHER,
    // correctly-read siblings are evidence too); the candidate line itself
    // contributes no gaps and is not counted as a crosser of its own bands.
    let nearRows = rows.filter { row in
        row.contains { j in abs(boxes[j].midY - line.midY) <= neighborhood }
    }

    // Per-row clear gaps between horizontally consecutive lines.
    struct Gap { let range: ClosedRange<CGFloat>; let row: Int }
    var gaps: [Gap] = []
    for (r, row) in nearRows.enumerated() {
        let sorted = row.filter { $0 != candidate }.map { boxes[$0] }.sorted { $0.minX < $1.minX }
        guard sorted.count >= 2 else { continue }
        for k in 0..<(sorted.count - 1) {
            let lo = sorted[k].maxX, hi = sorted[k + 1].minX
            if hi - lo >= minGutterWidth { gaps.append(Gap(range: lo...hi, row: r)) }
        }
    }
    guard gaps.count >= gutterMinSupportRows else { return [] }

    // Cluster gaps by running intersection: aligned gaps from different rows
    // narrow to the true gutter; a gap that can't keep the intersection wide
    // enough starts a new cluster.
    gaps.sort { $0.range.lowerBound < $1.range.lowerBound }
    var clusters: [(band: ClosedRange<CGFloat>, rows: Set<Int>)] = []
    for gap in gaps {
        if let last = clusters.indices.last {
            let band = clusters[last].band
            let lo = max(band.lowerBound, gap.range.lowerBound)
            let hi = min(band.upperBound, gap.range.upperBound)
            if hi - lo >= minGutterWidth {
                clusters[last].band = lo...hi
                clusters[last].rows.insert(gap.row)
                continue
            }
        }
        clusters.append((gap.range, [gap.row]))
    }

    var accepted: [ClosedRange<CGFloat>] = []
    for cluster in clusters {
        let support = cluster.rows.count
        guard support >= gutterMinSupportRows else { continue }
        // A band anchored on a tile seam is fragment residue, not a gutter.
        guard !seams.contains(where: {
            abs($0 - cluster.band.lowerBound) <= gutterSeamEdgeTolerance
                || abs($0 - cluster.band.upperBound) <= gutterSeamEdgeTolerance
        }) else { continue }
        // The candidate must span the band with real content on both sides.
        guard line.minX <= cluster.band.lowerBound - minGutterWidth,
              line.maxX >= cluster.band.upperBound + minGutterWidth else { continue }
        // Crossing veto: rows whose (body-height) lines flow straight across
        // the band outvote it — an aligned gap in prose is not a gutter.
        let crossers = nearRows.indices.filter { r in
            nearRows[r].contains { j in
                j != candidate && boxes[j].height <= heightGate
                    && boxes[j].minX <= cluster.band.lowerBound
                    && boxes[j].maxX >= cluster.band.upperBound
            }
        }.count
        let fraction = CGFloat(support) / CGFloat(support + crossers)
        guard fraction >= gutterMinSupportFraction else { continue }
        accepted.append(cluster.band)
    }
    // Keep bands disjoint (greedy left→right) so segment construction is sane.
    accepted.sort { $0.lowerBound < $1.lowerBound }
    var disjoint: [ClosedRange<CGFloat>] = []
    for band in accepted where disjoint.last.map({ band.lowerBound > $0.upperBound }) ?? true {
        disjoint.append(band)
    }
    return disjoint
}

// MARK: - Repair construction

/// Split `line` at the gutter bands' MIDPOINTS: the segments tile the line's
/// entire span with no interior excluded. This makes a wrong vote LOSSLESS —
/// if a band is false (or too wide), every glyph still lands inside some
/// segment and survives the re-read as two boxes instead of vanishing. (An
/// earlier version excluded band interiors for tighter crops; a false band
/// then silently deleted the text inside it.) Slivers narrower than
/// `minWidth` are dropped.
private func subBoxes(of line: CGRect, splitAt bands: [ClosedRange<CGFloat>],
                      minWidth: CGFloat) -> [CGRect] {
    var cuts: [CGFloat] = [line.minX]
    cuts.append(contentsOf: bands.map { ($0.lowerBound + $0.upperBound) / 2 })
    cuts.append(line.maxX)
    return (0..<(cuts.count - 1)).compactMap { k in
        cuts[k + 1] - cuts[k] >= minWidth
            ? CGRect(x: cuts[k], y: line.minY,
                     width: cuts[k + 1] - cuts[k], height: line.height) : nil
    }
}

/// A spanning line is redundant when every segment is already covered (in X,
/// on its own visual row) by another line — the per-cell reads coexist, so
/// the merged read adds nothing.
private func isRedundant(line: Int, segments: [CGRect], boxes: [CGRect],
                         rows: [[Int]], rowOf: [Int]) -> Bool {
    guard rowOf.indices.contains(line), rowOf[line] >= 0 else { return false }
    let siblings = rows[rowOf[line]].filter { $0 != line }
    guard !siblings.isEmpty else { return false }
    return segments.allSatisfy { segment in
        siblings.contains { j in
            let overlap = min(segment.maxX, boxes[j].maxX) - max(segment.minX, boxes[j].minX)
            return overlap >= segment.width * redundantCoverageFraction
        }
    }
}

// MARK: - Row grouping

/// Group line indices into visual rows: sweep top-to-bottom, a line joins the
/// current row when it overlaps the row's running vertical band by more than
/// `rowOverlapFraction` of the shorter height.
private func visualRows(_ boxes: [CGRect]) -> [[Int]] {
    let order = boxes.indices.sorted { boxes[$0].midY < boxes[$1].midY }
    var rows: [[Int]] = []
    var bandMinY: CGFloat = 0, bandMaxY: CGFloat = 0
    for i in order {
        let b = boxes[i]
        if var row = rows.last {
            let overlap = min(bandMaxY, b.maxY) - max(bandMinY, b.minY)
            let shorter = min(bandMaxY - bandMinY, b.height)
            if shorter > 0, overlap / shorter > rowOverlapFraction {
                row.append(i)
                rows[rows.count - 1] = row
                bandMinY = min(bandMinY, b.minY)
                bandMaxY = max(bandMaxY, b.maxY)
                continue
            }
        }
        rows.append([i])
        bandMinY = b.minY
        bandMaxY = b.maxY
    }
    return rows
}

/// Inverse of `visualRows`: row index per line (-1 unreachable by construction).
private func rowIndexByLine(_ rows: [[Int]], count: Int) -> [Int] {
    var out = [Int](repeating: -1, count: count)
    for (r, row) in rows.enumerated() {
        for i in row { out[i] = r }
    }
    return out
}

private func median(_ values: [CGFloat]) -> CGFloat {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}
