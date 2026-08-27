import XCTest
@testable import Sealshot

final class TableReconstructorColumnsTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a token whose midX is (x + w/2). Boundaries are interior x-cuts in [0,1].
    private func tok(_ t: String, midX: CGFloat, midY: CGFloat = 0.1) -> LayoutToken {
        let w: CGFloat = 0.04
        let h: CGFloat = 0.02
        return LayoutToken(text: t, rect: CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h))
    }

    // MARK: - assignColumns

    /// Three-column table (boundaries [0.33, 0.66]).
    /// Token "A" in col 0, "B" in col 1, "C" in col 2.
    func test_assignColumns_threeTokens_landInThreeColumns() {
        let row = [tok("A", midX: 0.10), tok("B", midX: 0.50), tok("C", midX: 0.80)]
        let result = TableReconstructor.assignColumns(row, boundaries: [0.33, 0.66])
        XCTAssertEqual(result, ["A", "B", "C"])
    }

    /// Middle column is empty (no token has midX in [0.33, 0.66)).
    func test_assignColumns_emptyMiddleColumn_yieldsEmptyString() {
        let row = [tok("Left", midX: 0.10), tok("Right", midX: 0.80)]
        let result = TableReconstructor.assignColumns(row, boundaries: [0.33, 0.66])
        XCTAssertEqual(result, ["Left", "", "Right"])
    }

    /// Two tokens share the same column — they are joined with a single space (left-to-right).
    func test_assignColumns_twoTokensInOneColumn_joinedWithSpace() {
        // Boundaries [0.5]: two columns. Put "Hello" and "World" both in col 0.
        let row = [tok("Hello", midX: 0.10), tok("World", midX: 0.25)]
        let result = TableReconstructor.assignColumns(row, boundaries: [0.5])
        XCTAssertEqual(result, ["Hello World", ""])
    }

    /// No boundaries → single column containing all tokens joined.
    func test_assignColumns_noBoundaries_singleColumn() {
        let row = [tok("X", midX: 0.2), tok("Y", midX: 0.7)]
        let result = TableReconstructor.assignColumns(row, boundaries: [])
        XCTAssertEqual(result, ["X Y"])
    }

    /// Empty row → all columns are empty strings.
    func test_assignColumns_emptyRow_allEmpty() {
        let result = TableReconstructor.assignColumns([], boundaries: [0.5])
        XCTAssertEqual(result, ["", ""])
    }

    // MARK: - geometryOrderedTranscript

    /// Two rows, each with two tokens. Tokens within a row are joined by space; rows by newline.
    func test_geometryOrderedTranscript_twoRows_spaceThenNewline() {
        let tokens = [
            tok("Row1A", midX: 0.1, midY: 0.1),
            tok("Row1B", midX: 0.6, midY: 0.1),
            tok("Row2A", midX: 0.1, midY: 0.5),
            tok("Row2B", midX: 0.6, midY: 0.5),
        ]
        let result = TableReconstructor.geometryOrderedTranscript(tokens, tolerance: 0.05)
        XCTAssertEqual(result, "Row1A Row1B\nRow2A Row2B")
    }

    /// Single token → no spaces or newlines inserted.
    func test_geometryOrderedTranscript_singleToken_noExtraWhitespace() {
        let result = TableReconstructor.geometryOrderedTranscript([tok("Solo", midX: 0.5)], tolerance: 0.05)
        XCTAssertEqual(result, "Solo")
    }

    /// Tokens presented in scrambled order are sorted into correct row/column order.
    func test_geometryOrderedTranscript_scrambledInput_orderedOutput() {
        // Deliberately add tokens out of row and column order.
        let tokens = [
            tok("C", midX: 0.8, midY: 0.1),
            tok("A", midX: 0.1, midY: 0.1),
            tok("B", midX: 0.5, midY: 0.1),
        ]
        let result = TableReconstructor.geometryOrderedTranscript(tokens, tolerance: 0.05)
        XCTAssertEqual(result, "A B C")
    }
}
