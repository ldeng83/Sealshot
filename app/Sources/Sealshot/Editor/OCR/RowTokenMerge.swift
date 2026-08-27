import CoreGraphics
import Foundation

/// Rebuild one line from the tile fragments that read it, at WORD level.
///
/// Tiles overlap by `ocrTileOverlap`, which is far wider than any word, so
/// every word of a split line is wholly inside at least one tile. That is the
/// property this merge rests on: somewhere among the fragments there is a
/// clean, uncut read of every word, and the job is to pick it — not to read
/// the line again.
///
/// The previous approach re-OCR'd the fragments' union from the full-res
/// source. For a heading that works, but a body-text line spanning the image
/// is a strip too wide to upscale (`upscaledForOCR` declines past 2600px), so
/// the re-read saw the text at HALF the resolution of the tile reads it was
/// replacing, and quietly returned less than it was given — a field capture
/// lost the middle of a sentence that every tile had read at confidence 1.00.
/// Merging what the tiles already read cannot lose text, and costs no Vision
/// pass at all.
///
/// One rule does the work: word-level non-max suppression, most-interior read
/// first. A cut-glyph remnant ("fo", "rmat.", a stray "1") is flush against
/// its fragment's seam edge, so the tile that read the whole word outranks it
/// and suppresses it. Nothing is discarded except in favour of another read of
/// the same word, which is what makes losing text structurally impossible.

/// One word of a fragment, with the geometry Vision validated for it.
struct RowToken: Equatable {
    let text: String
    let box: CGRect
    let charBoxes: [CGRect]
    let conf: Float
    /// Distance from this token to the nearest x-edge of the fragment it came
    /// from. A token flush against an edge was likely cut by the tile seam, so
    /// this ranks competing reads of the same word: bigger margin, more
    /// context around the glyphs, better read.
    let edgeMargin: CGFloat
}

/// Split `line` into whitespace-separated tokens, unioning the per-character
/// boxes of each run. Empty when the char boxes don't line up with the text —
/// callers fall back to the unmerged fragments rather than guess at geometry.
func rowTokens(of line: RecognizedLine, conf: Float) -> [RowToken] {
    let chars = line.characters
    let boxes = line.charBoxes
    guard chars.count == boxes.count, !chars.isEmpty else { return [] }

    var out: [RowToken] = []
    var i = 0
    while i < chars.count {
        guard !chars[i].isWhitespace else { i += 1; continue }
        var j = i
        while j < chars.count, !chars[j].isWhitespace { j += 1 }
        let slice = Array(boxes[i..<j])
        let box = slice.reduce(CGRect.null) { $0.union($1) }
        if !box.isNull, box.width > 0 {
            out.append(RowToken(
                text: String(chars[i..<j]), box: box, charBoxes: slice, conf: conf,
                edgeMargin: min(box.minX - line.box.minX, line.box.maxX - box.maxX)))
        }
        i = j
    }
    return out
}

/// Two boxes describe the same word: they overlap in x by more than half the
/// narrower one, and share the row vertically. Distinct words on a line are
/// separated by a space gap and never reach this bar.
func sameWordBoxes(_ a: CGRect, _ b: CGRect) -> Bool {
    let xOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
    guard xOverlap > 0.5 * min(a.width, b.width) else { return false }
    let yOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
    return yOverlap > 0.5 * min(a.height, b.height)
}

/// Merge same-row fragments into a single line. nil when there is nothing to
/// merge from — the caller keeps the fragments untouched rather than lose text.
func mergeRowFragments(_ items: [(line: RecognizedLine, conf: Float)])
    -> (line: RecognizedLine, conf: Float)? {
    guard items.count > 1 else { return items.first }
    let candidates = items.flatMap { rowTokens(of: $0.line, conf: $0.conf) }
    guard !candidates.isEmpty else { return nil }

    // Word-level non-max suppression: the best read of each word wins and
    // suppresses the others. Ranked by how much context surrounded the token,
    // then Vision's confidence, then length — a cut-glyph remnant ("fo") is
    // flush against its fragment's seam edge and shorter than the whole word
    // ("format."), so it loses on both counts and is suppressed by it.
    //
    // Suppression is the ONLY way a token leaves. Dropping seam debris up
    // front looked tidier and silently deleted words: when a word sits at the
    // seam, BOTH tiles read it flush against an edge, each is covered by the
    // other's fragment, and an eager filter removes both copies — the exact
    // failure this merge replaced. A token can only be discarded in favour of
    // a surviving read of the same word.
    let ranked = candidates.sorted {
        ($0.edgeMargin, $0.conf, $0.text.count) > ($1.edgeMargin, $1.conf, $1.text.count)
    }
    var kept: [RowToken] = []
    for token in ranked where !kept.contains(where: { sameWordBoxes($0.box, token.box) }) {
        kept.append(token)
    }
    kept.sort { $0.box.minX < $1.box.minX }
    guard let first = kept.first else { return nil }

    // 3. Rebuild text and geometry together, so selection still highlights the
    //    right glyphs. Separators get the gap they actually span, matching what
    //    `tokenAwareCharacterBoxes` does for spaces within a single read.
    var text = first.text
    var charBoxes = first.charBoxes
    for (previous, token) in zip(kept, kept.dropFirst()) {
        text.append(" ")
        let gapWidth = max(0, token.box.minX - previous.box.maxX)
        let vertical = previous.box.union(token.box)
        charBoxes.append(CGRect(x: previous.box.maxX, y: vertical.minY,
                                width: gapWidth, height: vertical.height))
        text += token.text
        charBoxes += token.charBoxes
    }

    let box = kept.map(\.box).reduce(CGRect.null) { $0.union($1) }
    return (RecognizedLine(text: text, box: box, charBoxes: charBoxes,
                           quad: mergedQuad(items: items, box: box)),
            // A merged line is only as trustworthy as its weakest word.
            kept.map(\.conf).min() ?? first.conf)
}

/// The outline for a merged line: the left edge of the leftmost fragment's
/// quad and the right edge of the rightmost one, so a tilted row (a photo of a
/// page rather than a screenshot) keeps its tilt. Falls back to the merged
/// box's corners when a fragment carried no quad.
private func mergedQuad(items: [(line: RecognizedLine, conf: Float)], box: CGRect) -> TextQuad? {
    guard let leftmost = items.min(by: { $0.line.box.minX < $1.line.box.minX })?.line,
          let rightmost = items.max(by: { $0.line.box.maxX < $1.line.box.maxX })?.line,
          let left = leftmost.quad, let right = rightmost.quad
    else {
        return TextQuad(topLeft: CGPoint(x: box.minX, y: box.minY),
                        topRight: CGPoint(x: box.maxX, y: box.minY),
                        bottomRight: CGPoint(x: box.maxX, y: box.maxY),
                        bottomLeft: CGPoint(x: box.minX, y: box.maxY))
    }
    return TextQuad(topLeft: left.topLeft, topRight: right.topRight,
                    bottomRight: right.bottomRight, bottomLeft: left.bottomLeft)
}
