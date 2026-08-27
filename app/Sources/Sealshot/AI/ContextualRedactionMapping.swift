import CoreGraphics
import Foundation

/// Confidence multiplier applied to a detection the model flags as a likely
/// false positive. We never remove it — just lower its confidence so the review
/// panel de-emphasizes it.
let falsePositiveConfidenceFactor: Double = 0.4

/// Locate a model-returned verbatim span inside a single OCR line. Returns the
/// line index and the span's Character range (matching `RecognizedLine.charBoxes`
/// indexing). nil when the span (trimmed) isn't found in any single line — we
/// only redact spans we can place precisely.
func locateSpan(_ span: String, inLineTexts lines: [String]) -> (lineIndex: Int, range: Range<Int>)? {
    let needle = span.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return nil }
    for (i, text) in lines.enumerated() {
        if let r = text.range(of: needle) {
            let lo = text.distance(from: text.startIndex, to: r.lowerBound)
            let hi = text.distance(from: text.startIndex, to: r.upperBound)
            return (i, lo..<hi)
        }
    }
    return nil
}

/// True when a detection's matched text was flagged by the model as a likely
/// false positive (exact match).
func isFalsePositive(_ text: String, flagged: Set<String>) -> Bool {
    flagged.contains(text)
}

/// Lower confidence for flagged false positives; leave others unchanged.
func dampedConfidence(base: Double, isFlaggedFalsePositive: Bool) -> Double {
    isFlaggedFalsePositive ? base * falsePositiveConfidenceFactor : base
}

/// Character-offset ranges of every non-overlapping occurrence of `needle` in
/// `text` that is a COMPLETE token: the character immediately before and after
/// the match is not a digit, letter, '.', or ',' — so a value is never matched
/// as a fragment of a larger number ("200" in "200,000") or word ("John" in
/// "Johnson"). Offsets index `Array(text)`, matching DetectionGeometry ranges.
func tokenOccurrences(of needle: String, in text: String) -> [Range<Int>] {
    let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let chars = Array(text)
    let n = Array(trimmed)
    guard !n.isEmpty, n.count <= chars.count else { return [] }
    func blocks(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "." || c == "," }
    var ranges: [Range<Int>] = []
    var i = 0
    while i <= chars.count - n.count {
        if Array(chars[i..<(i + n.count)]) == n {
            let before = (i == 0) || !blocks(chars[i - 1])
            let after = (i + n.count == chars.count) || !blocks(chars[i + n.count])
            if before && after {
                ranges.append(i..<(i + n.count))
                i += n.count          // non-overlapping
                continue
            }
        }
        i += 1
    }
    return ranges
}

/// Like `spanRects`, but maps a single-line value to EVERY token occurrence in
/// the layout (so repeated values redact every instance). Multi-line spans
/// delegate to `spanRects`; if no whole-token occurrence is found, falls back to
/// `spanRects` (first occurrence) so a detection is never lost. Pure.
func spanRectsAllOccurrences(_ spanText: String, in layout: RecognizedTextLayout, tile: CGRect) -> [CGRect] {
    let needle = spanText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    if needle.contains("\n") { return spanRects(spanText, in: layout, tile: tile) }
    func rect(line i: Int, range: Range<Int>) -> CGRect? {
        guard layout.lines.indices.contains(i),
              let nb = DetectionGeometry.normalizedBox(for: range, in: layout.lines[i]) else { return nil }
        return DetectionGeometry.imageRect(fromNormalized: nb, imageSize: tile.size)
            .offsetBy(dx: tile.minX, dy: tile.minY)
    }
    var rects: [CGRect] = []
    for (i, line) in layout.lines.enumerated() {
        for range in tokenOccurrences(of: needle, in: line.text) {
            if let r = rect(line: i, range: range) { rects.append(r) }
        }
    }
    return rects.isEmpty ? spanRects(spanText, in: layout, tile: tile) : rects
}

/// Map an OCR span to image-space rect(s). A single-line span yields one rect
/// (today's behavior). A span whose text crosses OCR line breaks (contains "\n",
/// e.g. a card number Vision split across lines) is split on "\n" and its
/// fragments located SEQUENTIALLY — each search starts after the previous
/// match's line — so an OCR-split value maps to its consecutive lines and a
/// duplicated token elsewhere doesn't mis-map. Pure.
func spanRects(_ spanText: String, in layout: RecognizedTextLayout, tile: CGRect) -> [CGRect] {
    let lineTexts = layout.lines.map(\.text)
    func rect(line i: Int, range: Range<Int>) -> CGRect? {
        guard layout.lines.indices.contains(i),
              let nb = DetectionGeometry.normalizedBox(for: range, in: layout.lines[i]) else { return nil }
        return DetectionGeometry.imageRect(fromNormalized: nb, imageSize: tile.size)
            .offsetBy(dx: tile.minX, dy: tile.minY)
    }
    // Single-line (no newline, or a whole-line match).
    if let loc = locateSpan(spanText, inLineTexts: lineTexts), let r = rect(line: loc.lineIndex, range: loc.range) {
        return [r]
    }
    // Multi-line: locate each fragment from the previous match's line onward.
    var rects: [CGRect] = []
    var searchStart = 0
    for frag in spanText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
        let f = frag.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, searchStart < lineTexts.count else { continue }
        let slice = Array(lineTexts[searchStart...])
        guard let loc = locateSpan(f, inLineTexts: slice) else { continue }
        let absIndex = searchStart + loc.lineIndex
        if let r = rect(line: absIndex, range: loc.range) { rects.append(r) }
        searchStart = absIndex + 1
    }
    return rects
}
