import AppKit
import XCTest
@testable import Sealshot

final class ImageTextSearchTests: XCTestCase {

    private func line(_ text: String, x: CGFloat = 0, y: CGFloat = 0.1,
                      charWidth: CGFloat = 0.05) -> RecognizedLine {
        let boxes = text.indices.map { index in
            let offset = text.distance(from: text.startIndex, to: index)
            return CGRect(x: x + CGFloat(offset) * charWidth, y: y,
                          width: charWidth, height: 0.1)
        }
        return RecognizedLine(
            text: text,
            box: boxes.reduce(CGRect.null) { $0.union($1) },
            charBoxes: boxes)
    }

    func testFindsEveryNonOverlappingOccurrenceInReadingOrder() {
        let layout = RecognizedTextLayout(lines: [
            line("April report April"),
            line("next APRIL", y: 0.3),
        ])

        let matches = findImageTextMatches(in: layout, query: "april")

        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map { layout.text(for: $0.selection) },
                       ["April", "April", "APRIL"])
        XCTAssertEqual(matches[0].selection.ordered.start, TextPosition(line: 0, char: 0))
        XCTAssertEqual(matches[1].selection.ordered.start, TextPosition(line: 0, char: 13))
        XCTAssertEqual(matches[2].selection.ordered.start, TextPosition(line: 1, char: 5))
    }

    func testResultsFollowDisplayOrderWhenOCRLinesAreShuffled() {
        let layout = RecognizedTextLayout(lines: [
            line("AM", x: 0.65, y: 0.105, charWidth: 0.04), // top-right
            line("AM", x: 0.12, y: 0.32, charWidth: 0.04),  // bottom-left
            line("AM", x: 0.10, y: 0.10, charWidth: 0.04),  // top-left
        ])

        let matches = findImageTextMatches(in: layout, query: "AM")

        XCTAssertEqual(matches.map(\.selection.ordered.start.line), [2, 0, 1])
    }

    func testNearbyRowsDoNotCollapseIntoHorizontalOrderOnTallCapture() {
        // These y values are less than 1% of the image apart, which made the
        // old whole-image row bucket merge them and put the lower-left match
        // before the upper-right match. Their boxes do not visually overlap,
        // so they are two distinct display rows.
        let upperRight = line("AM", x: 0.70, y: 0.100, charWidth: 0.02)
        let lowerLeft = RecognizedLine(
            text: "AM",
            box: CGRect(x: 0.10, y: 0.109, width: 0.04, height: 0.006),
            charBoxes: [
                CGRect(x: 0.10, y: 0.109, width: 0.02, height: 0.006),
                CGRect(x: 0.12, y: 0.109, width: 0.02, height: 0.006),
            ])
        let resizedUpperRight = RecognizedLine(
            text: upperRight.text,
            box: CGRect(x: 0.70, y: 0.100, width: 0.04, height: 0.006),
            charBoxes: [
                CGRect(x: 0.70, y: 0.100, width: 0.02, height: 0.006),
                CGRect(x: 0.72, y: 0.100, width: 0.02, height: 0.006),
            ])
        let layout = RecognizedTextLayout(lines: [lowerLeft, resizedUpperRight])

        let matches = findImageTextMatches(in: layout, query: "AM")

        XCTAssertEqual(matches.map(\.selection.ordered.start.line), [1, 0])
    }

    func testMatchingIsDiacriticInsensitiveButKeepsOriginalOffsets() {
        let layout = RecognizedTextLayout(lines: [line("Café receipt")])

        let matches = findImageTextMatches(in: layout, query: "cafe")

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(layout.text(for: matches[0].selection), "Café")
        XCTAssertEqual(matches[0].selection.ordered.start.char, 0)
        XCTAssertEqual(matches[0].selection.ordered.end.char, 4)
    }

    func testFocusScopeKeepsOnlyMatchesWhoseCentersAreInsideFocus() {
        let layout = RecognizedTextLayout(lines: [line("April xx April")])
        let focus = CGRect(x: 0.42, y: 0, width: 0.4, height: 0.3)

        let matches = findImageTextMatches(
            in: layout, query: "April", scope: .focusArea,
            normalizedFocusRect: focus)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].selection.ordered.start.char, 9)
    }

    func testFocusScopeWithoutFocusHasNoMatches() {
        let layout = RecognizedTextLayout(lines: [line("April")])
        XCTAssertTrue(findImageTextMatches(
            in: layout, query: "April", scope: .focusArea,
            normalizedFocusRect: nil).isEmpty)
    }

    func testBlankQueryHasNoMatches() {
        let layout = RecognizedTextLayout(lines: [line("April")])
        XCTAssertTrue(findImageTextMatches(in: layout, query: "   ").isEmpty)
    }

    func testPartiallyVisibleHighlightNeedsRevealWithMargin() {
        let viewport = CGRect(x: 0, y: 0, width: 600, height: 400)
        let clippedAtBottom = CGRect(x: 250, y: 385, width: 80, height: 30)

        XCTAssertTrue(viewport.intersects(clippedAtBottom))
        XCTAssertTrue(imageTextSearchNeedsReveal(
            highlightRect: clippedAtBottom, visibleRect: viewport, margin: 40))
        XCTAssertEqual(imageTextSearchRevealRect(for: clippedAtBottom, margin: 40),
                       CGRect(x: 210, y: 345, width: 160, height: 110))
    }

    func testHighlightWithFullMarginDoesNotMoveViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 600, height: 400)
        let comfortablyVisible = CGRect(x: 250, y: 160, width: 80, height: 30)

        XCTAssertFalse(imageTextSearchNeedsReveal(
            highlightRect: comfortablyVisible, visibleRect: viewport, margin: 40))
    }

    func testFieldEditorReturnCommandsMapToNavigationDirection() {
        let selectors = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertLineBreak(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
        ]

        for selector in selectors {
            XCTAssertEqual(imageTextSearchEditingCommand(
                for: selector, modifierFlags: []), .moveResult(1))
            XCTAssertEqual(imageTextSearchEditingCommand(
                for: selector, modifierFlags: [.shift]), .moveResult(-1))
        }
    }

    @MainActor
    func testPanelConsumesFieldEditorReturnAndMovesResult() {
        let panel = ImageTextSearchPanel(
            query: "AM", scope: .wholeImage, focusAreaAvailable: false,
            status: .matches(current: 0, total: 2))
        var moves: [Int] = []
        panel.onMoveResult = { moves.append($0) }

        let handled = panel.control(
            NSSearchField(), textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertTrue(handled)
        XCTAssertEqual(moves, [1])
    }

    func testMatchBoundsUseOCRCharacterBoxesInsteadOfWholeLineFractions() {
        // Simulates proportional text: the first word is narrow and the target
        // begins after a wide visual gap. Search highlighting must preserve the
        // OCR geometry Smart Redaction consumes, not re-slice the whole line.
        let boxes = [
            CGRect(x: 0.05, y: 0.2, width: 0.03, height: 0.1),
            CGRect(x: 0.08, y: 0.2, width: 0.03, height: 0.1),
            CGRect(x: 0.11, y: 0.2, width: 0.03, height: 0.1),
            CGRect(x: 0.14, y: 0.2, width: 0.03, height: 0.1),
            CGRect(x: 0.17, y: 0.2, width: 0.03, height: 0.1),
            CGRect(x: 0.20, y: 0.2, width: 0.10, height: 0.1),
            CGRect(x: 0.55, y: 0.2, width: 0.06, height: 0.1),
            CGRect(x: 0.61, y: 0.2, width: 0.06, height: 0.1),
            CGRect(x: 0.67, y: 0.2, width: 0.06, height: 0.1),
        ]
        let recognized = RecognizedLine(
            text: "small KEY", box: boxes.reduce(CGRect.null) { $0.union($1) },
            charBoxes: boxes)

        let match = findImageTextMatches(
            in: RecognizedTextLayout(lines: [recognized]), query: "KEY").first

        let bounds = try? XCTUnwrap(match?.bounds)
        XCTAssertEqual(bounds?.minX ?? 0, 0.55, accuracy: 0.0001)
        XCTAssertEqual(bounds?.minY ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(bounds?.width ?? 0, 0.18, accuracy: 0.0001)
        XCTAssertEqual(bounds?.height ?? 0, 0.1, accuracy: 0.0001)
    }
}
