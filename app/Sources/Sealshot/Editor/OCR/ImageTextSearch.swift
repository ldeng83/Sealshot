import Foundation

/// Which part of the displayed image contributes Find in Image results.
enum ImageTextSearchScope: Equatable {
    case wholeImage
    case focusArea
}

/// One OCR-backed text match, including the character selection used to draw
/// precise line/tilt-following highlights and its normalized image bounds.
struct ImageTextSearchMatch: Equatable {
    let selection: TextSelection
    let bounds: CGRect
}

/// Compact state shared by the canvas and sidebar. `current` is zero-based;
/// the sidebar adds one for the familiar “1 of N” presentation.
enum ImageTextSearchStatus: Equatable {
    case idle
    case recognizing
    case noText
    case noMatches
    case matches(current: Int, total: Int)
}

/// Search stays behind a waiting panel until Live Text's first OCR pass over
/// the displayed base lands. Live Text reads whatever base is on screen, so
/// there is nothing else to wait for.
enum ImageTextSearchScanStage: Equatable {
    case recognizingCurrentBase
    case ready

    var isReady: Bool { self == .ready }
}

/// View-space breathing room kept around the active result when Search moves
/// the canvas. This prevents a technically visible highlight from sitting
/// flush against (or being clipped by) a viewport edge.
let imageTextSearchRevealMargin: CGFloat = 40

func imageTextSearchRevealRect(for highlightRect: CGRect,
                               margin: CGFloat = imageTextSearchRevealMargin) -> CGRect {
    highlightRect.insetBy(dx: -margin, dy: -margin)
}

func imageTextSearchNeedsReveal(highlightRect: CGRect, visibleRect: CGRect,
                                margin: CGFloat = imageTextSearchRevealMargin) -> Bool {
    !visibleRect.contains(imageTextSearchRevealRect(for: highlightRect, margin: margin))
}

/// Case- and diacritic-insensitive literal search over OCR lines. Matches are
/// returned in display order (top-to-bottom rows, left-to-right within a row)
/// and retain original character offsets, so transformed comparisons (for
/// example “cafe” matching “Café”) still map to the correct glyph boxes.
func findImageTextMatches(
    in layout: RecognizedTextLayout,
    query rawQuery: String,
    scope: ImageTextSearchScope = .wholeImage,
    normalizedFocusRect: CGRect? = nil
) -> [ImageTextSearchMatch] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    var matches: [ImageTextSearchMatch] = []
    for (lineIndex, line) in layout.lines.enumerated() {
        var searchStart = line.text.startIndex
        while searchStart < line.text.endIndex,
              let range = line.text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<line.text.endIndex,
                locale: .current) {
            let lower = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
            let upper = line.text.distance(from: line.text.startIndex, to: range.upperBound)
            let selection = TextSelection(
                anchor: TextPosition(line: lineIndex, char: lower),
                focus: TextPosition(line: lineIndex, char: upper))

            if let bounds = layout.boxes(for: selection).first {
                let isInScope: Bool
                switch scope {
                case .wholeImage:
                    isInScope = true
                case .focusArea:
                    guard let focus = normalizedFocusRect else {
                        isInScope = false
                        break
                    }
                    isInScope = focus.contains(CGPoint(x: bounds.midX, y: bounds.midY))
                }
                if isInScope {
                    matches.append(ImageTextSearchMatch(selection: selection, bounds: bounds))
                }
            }

            // Literal matches are non-overlapping, matching native Find behavior.
            searchStart = range.upperBound
        }
    }
    return matchesInDisplayOrder(matches)
}

/// Vision's observation order is usually, but not reliably, visual reading
/// order. Sort from the match geometry instead. Row membership is based on the
/// highlights' own heights rather than a percentage of the entire image, which
/// is important for very tall scroll captures: a 1%-of-image bucket can be
/// taller than several visible text rows and incorrectly sort them by x.
private func matchesInDisplayOrder(_ matches: [ImageTextSearchMatch]) -> [ImageTextSearchMatch] {
    guard matches.count > 1 else { return matches }

    struct DisplayRow {
        var bounds: CGRect
        var matches: [ImageTextSearchMatch]
    }

    let topFirst = matches.sorted { lhs, rhs in
        if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
        return lhs.bounds.minX < rhs.bounds.minX
    }
    var rows: [DisplayRow] = []

    for match in topFirst {
        if let last = rows.indices.last,
           belongsToSameDisplayRow(match.bounds, rows[last].bounds) {
            rows[last].bounds = rows[last].bounds.union(match.bounds)
            rows[last].matches.append(match)
        } else {
            rows.append(DisplayRow(bounds: match.bounds, matches: [match]))
        }
    }

    return rows.flatMap { row in
        row.matches.sorted { lhs, rhs in
            if lhs.bounds.minX != rhs.bounds.minX { return lhs.bounds.minX < rhs.bounds.minX }
            return lhs.bounds.minY < rhs.bounds.minY
        }
    }
}

private func belongsToSameDisplayRow(_ candidate: CGRect, _ row: CGRect) -> Bool {
    let shorterHeight = min(candidate.height, row.height)
    guard shorterHeight > 0 else { return false }
    let overlap = min(candidate.maxY, row.maxY) - max(candidate.minY, row.minY)
    return overlap >= shorterHeight * 0.45
}
