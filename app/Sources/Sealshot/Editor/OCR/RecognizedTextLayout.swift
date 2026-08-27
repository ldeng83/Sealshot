import Foundation

/// Four corner points of a recognized line, normalized [0,1] top-left origin.
/// Unlike the axis-aligned `box`, the quad follows the text's baseline tilt
/// (Vision's rectangle-observation corners), so the highlight outline can hug
/// slanted text instead of a too-tall upright rectangle.
struct TextQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// Build from Vision's bottom-left-origin corners, flipping Y to the
    /// top-left-origin space the rest of the OCR layout uses. The tilt is
    /// preserved because every corner is flipped identically.
    static func fromVisionCorners(topLeft: CGPoint, topRight: CGPoint,
                                  bottomLeft: CGPoint, bottomRight: CGPoint) -> TextQuad {
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        return TextQuad(topLeft: flip(topLeft), topRight: flip(topRight),
                        bottomRight: flip(bottomRight), bottomLeft: flip(bottomLeft))
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// The sub-quad covering character fractions `[from, to]` of this line,
    /// interpolated along the top (TL→TR) and bottom (BL→BR) edges. Used to
    /// draw a selection highlight that follows the tilt and stays inside the
    /// outline (it is, by construction, a slice of this quad).
    func span(fromFraction from: CGFloat, toFraction to: CGFloat) -> TextQuad {
        TextQuad(topLeft: Self.lerp(topLeft, topRight, from),
                 topRight: Self.lerp(topLeft, topRight, to),
                 bottomRight: Self.lerp(bottomLeft, bottomRight, to),
                 bottomLeft: Self.lerp(bottomLeft, bottomRight, from))
    }

    /// Shrink the quad vertically toward its horizontal centerline by `fraction`
    /// of its height (half off the top, half off the bottom) so the outline hugs
    /// the text and adjacent lines don't visually merge.
    func insetVertically(by fraction: CGFloat) -> TextQuad {
        let k = fraction / 2
        return TextQuad(topLeft: Self.lerp(topLeft, bottomLeft, k),
                        topRight: Self.lerp(topRight, bottomRight, k),
                        bottomRight: Self.lerp(bottomRight, topRight, k),
                        bottomLeft: Self.lerp(bottomLeft, topLeft, k))
    }

    /// True if `p` is inside this (convex) quad. Used for line hit-testing: the
    /// tightened quads don't overlap, so containment unambiguously identifies
    /// the clicked row even where tilted lines' axis-aligned hulls overlap.
    func contains(_ p: CGPoint) -> Bool {
        let pts = [topLeft, topRight, bottomRight, bottomLeft]
        var sign = 0
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            let s = cross > 0 ? 1 : (cross < 0 ? -1 : 0)
            if s != 0 {
                if sign == 0 { sign = s } else if s != sign { return false }
            }
        }
        return true
    }

    /// Centroid of the four corners (a stable "center" for nearest-line ties).
    var center: CGPoint {
        CGPoint(x: (topLeft.x + topRight.x + bottomRight.x + bottomLeft.x) / 4,
                y: (topLeft.y + topRight.y + bottomRight.y + bottomLeft.y) / 4)
    }

    /// Where `p` falls along the line's reading direction, 0 (start) → 1 (end),
    /// by projecting onto the left-mid → right-mid axis. Caret index =
    /// round(parameter * characterCount), so the caret follows the tilt.
    func parameter(at p: CGPoint) -> CGFloat {
        let midLeft = CGPoint(x: (topLeft.x + bottomLeft.x) / 2, y: (topLeft.y + bottomLeft.y) / 2)
        let midRight = CGPoint(x: (topRight.x + bottomRight.x) / 2, y: (topRight.y + bottomRight.y) / 2)
        let ax = midRight.x - midLeft.x, ay = midRight.y - midLeft.y
        let len2 = ax * ax + ay * ay
        guard len2 > 0 else { return 0 }
        let t = ((p.x - midLeft.x) * ax + (p.y - midLeft.y) * ay) / len2
        return max(0, min(1, t))
    }
}

/// One recognized line of text. `box`, `quad` and `charBoxes` are in normalized
/// [0,1], top-left-origin space. `charBoxes.count == text.count`. `quad` is the
/// tilt-following outline; `box` is its axis-aligned hull (used for hit-testing).
struct RecognizedLine: Equatable {
    let text: String
    let box: CGRect
    let quad: TextQuad?
    let charBoxes: [CGRect]
    /// Characters as an array for index math (computed once at init since
    /// String is not random-access by integer index).
    let characters: [Character]

    init(text: String, box: CGRect, charBoxes: [CGRect], quad: TextQuad? = nil) {
        self.text = text
        self.box = box
        self.quad = quad
        self.charBoxes = charBoxes
        self.characters = Array(text)
    }
}

/// The full OCR result: lines in reading order (top→bottom, then left→right).
/// All geometry is normalized [0,1], top-left origin.
struct RecognizedTextLayout: Equatable {
    let lines: [RecognizedLine]

    var isEmpty: Bool { lines.isEmpty || lines.allSatisfy { $0.text.isEmpty } }

    var fullSelection: TextSelection {
        guard let last = lines.indices.last else {
            return .collapsed(at: TextPosition(line: 0, char: 0))
        }
        return TextSelection(anchor: TextPosition(line: 0, char: 0),
                             focus: TextPosition(line: last, char: lines[last].charBoxes.count))
    }

    /// Nearest caret position to a normalized point. Picks the line whose quad
    /// (or box, for quad-less layouts) contains/is-closest-to the point, then the
    /// caret index within that line — by tilt fraction when a quad is present,
    /// otherwise by `point.x`.
    func position(at point: CGPoint) -> TextPosition {
        guard !lines.isEmpty else { return TextPosition(line: 0, char: 0) }
        let lineIdx = lineIndex(at: point)
        return TextPosition(line: lineIdx, char: charIndex(in: lineIdx, at: point))
    }

    /// The glyph (0..<count) under `point` on its line — the floor of the tilt
    /// fraction, so a click anywhere within a character maps to that character
    /// (not the nearest caret boundary). Used to make drag selection inclusive.
    func glyphPosition(at point: CGPoint) -> TextPosition {
        guard !lines.isEmpty else { return TextPosition(line: 0, char: 0) }
        let lineIdx = lineIndex(at: point)
        let count = lines[lineIdx].characters.count
        guard count > 0 else { return TextPosition(line: lineIdx, char: 0) }
        let fraction: CGFloat
        if let quad = lines[lineIdx].quad {
            fraction = quad.parameter(at: point)
        } else {
            // Quad-less (synthetic) lines: locate the char box the x falls in.
            let boxes = lines[lineIdx].charBoxes
            var g = boxes.count - 1
            for (i, b) in boxes.enumerated() where point.x < b.maxX { g = i; break }
            return TextPosition(line: lineIdx, char: max(0, min(g, count - 1)))
        }
        let g = min(Int(fraction * CGFloat(count)), count - 1)
        return TextPosition(line: lineIdx, char: max(0, g))
    }

    /// Character-inclusive selection between two drag points: covers every glyph
    /// from the earlier point's glyph through the later point's glyph, inclusive,
    /// so the characters under BOTH the press and the release are selected (no
    /// off-by-one at the start or end).
    func dragSelection(from a: CGPoint, to b: CGPoint) -> TextSelection {
        let ga = glyphPosition(at: a)
        let gb = glyphPosition(at: b)
        let (lo, hi) = (ga.line, ga.char) <= (gb.line, gb.char) ? (ga, gb) : (gb, ga)
        return TextSelection(anchor: TextPosition(line: lo.line, char: lo.char),
                             focus: TextPosition(line: hi.line, char: hi.char + 1))
    }

    /// Whitespace-delimited word containing `point`, as a selection. nil if no
    /// line is hit or the caret lands on whitespace.
    func wordRange(at point: CGPoint) -> TextSelection? {
        guard !lines.isEmpty else { return nil }
        let lineIdx = lineIndex(at: point)
        let chars = lines[lineIdx].characters
        guard !chars.isEmpty else { return nil }
        var idx = charIndex(in: lineIdx, at: point)
        if idx >= chars.count { idx = chars.count - 1 }
        guard !chars[idx].isWhitespace else { return nil }
        var start = idx
        while start > 0 && !chars[start - 1].isWhitespace { start -= 1 }
        var end = idx
        while end < chars.count && !chars[end].isWhitespace { end += 1 }
        return TextSelection(anchor: TextPosition(line: lineIdx, char: start),
                             focus: TextPosition(line: lineIdx, char: end))
    }

    /// Selected text, lines joined by "\n".
    func text(for selection: TextSelection) -> String {
        let (start, end) = selection.ordered
        guard !lines.isEmpty, start != end else { return "" }
        if start.line == end.line {
            return slice(line: start.line, from: start.char, to: end.char)
        }
        var parts: [String] = [slice(line: start.line, from: start.char,
                                      to: lines[start.line].characters.count)]
        for l in (start.line + 1)..<end.line {
            parts.append(lines[l].text)
        }
        parts.append(slice(line: end.line, from: 0, to: end.char))
        return parts.joined(separator: "\n")
    }

    /// One tilted selection polygon per covered line, carved from each line's
    /// quad so the highlight follows the text tilt and stays inside the outline.
    /// Lines without a quad (synthetic/test layouts) are skipped — the caller
    /// falls back to `boxes(for:)` for those.
    func quads(for selection: TextSelection) -> [TextQuad] {
        let (start, end) = selection.ordered
        guard !lines.isEmpty, start != end else { return [] }
        var out: [TextQuad] = []
        for l in start.line...end.line {
            guard let quad = lines[l].quad else { continue }
            let n = lines[l].characters.count
            guard n > 0 else { continue }
            let lo = (l == start.line) ? start.char : 0
            let hi = (l == end.line) ? end.char : n
            let loC = max(0, min(lo, n)), hiC = max(loC, min(hi, n))
            guard loC < hiC else { continue }
            out.append(quad.span(fromFraction: CGFloat(loC) / CGFloat(n),
                                 toFraction: CGFloat(hiC) / CGFloat(n)))
        }
        return out
    }

    /// One union rect per covered line, for highlight drawing (normalized).
    func boxes(for selection: TextSelection) -> [CGRect] {
        let (start, end) = selection.ordered
        guard !lines.isEmpty, start != end else { return [] }
        var out: [CGRect] = []
        for l in start.line...end.line {
            let lo = (l == start.line) ? start.char : 0
            let hi = (l == end.line) ? end.char : lines[l].characters.count
            if let rect = unionCharBoxes(line: l, from: lo, to: hi) { out.append(rect) }
        }
        return out
    }

    // MARK: - Helpers

    /// The line the point falls on. When lines carry quads (real OCR), prefer
    /// the line whose tight quad CONTAINS the point — these don't overlap, so a
    /// click on a tilted/closely-spaced row resolves to that row instead of the
    /// neighbour whose tall axis-aligned hull also covers the point. Falls back
    /// to nearest quad center, then to the box-based logic for quad-less layouts.
    private func lineIndex(at point: CGPoint) -> Int {
        if lines.contains(where: { $0.quad != nil }) {
            func centerDistSq(_ i: Int) -> CGFloat {
                let c = lines[i].quad?.center ?? CGPoint(x: lines[i].box.midX, y: lines[i].box.midY)
                let dx = point.x - c.x, dy = point.y - c.y
                return dx * dx + dy * dy
            }
            let containing = lines.indices.filter { lines[$0].quad?.contains(point) ?? false }
            if let best = containing.min(by: { centerDistSq($0) < centerDistSq($1) }) { return best }
            return lines.indices.min(by: { centerDistSq($0) < centerDistSq($1) }) ?? 0
        }
        func rectDistanceSq(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return dx * dx + dy * dy
        }
        func centerDistanceSq(_ r: CGRect) -> CGFloat {
            let dx = point.x - r.midX, dy = point.y - r.midY
            return dx * dx + dy * dy
        }
        return lines.indices.min { a, b in
            let da = rectDistanceSq(lines[a].box), db = rectDistanceSq(lines[b].box)
            if da != db { return da < db }
            return centerDistanceSq(lines[a].box) < centerDistanceSq(lines[b].box)
        } ?? 0
    }

    /// Caret index within a line for a click point: by tilt fraction along the
    /// quad when present (so the caret tracks slanted text), else by `point.x`
    /// against the axis-aligned char boxes.
    private func charIndex(in lineIdx: Int, at point: CGPoint) -> Int {
        let count = lines[lineIdx].characters.count
        if let quad = lines[lineIdx].quad, count > 0 {
            let idx = Int((quad.parameter(at: point) * CGFloat(count)).rounded())
            return max(0, min(idx, count))
        }
        let charBoxes = lines[lineIdx].charBoxes
        for (i, b) in charBoxes.enumerated() {
            if point.x < b.midX { return i }
        }
        return charBoxes.count
    }

    private func slice(line: Int, from: Int, to: Int) -> String {
        let chars = lines[line].characters
        let lo = max(0, min(from, chars.count))
        let hi = max(lo, min(to, chars.count))
        return String(chars[lo..<hi])
    }

    private func unionCharBoxes(line: Int, from: Int, to: Int) -> CGRect? {
        let charBoxes = lines[line].charBoxes
        let lo = max(0, min(from, charBoxes.count))
        let hi = max(lo, min(to, charBoxes.count))
        guard lo < hi else { return nil }
        return charBoxes[lo..<hi].reduce(CGRect.null) { $0.union($1) }
    }
}
