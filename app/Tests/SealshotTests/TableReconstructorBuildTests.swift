import XCTest
@testable import Sealshot

final class TableReconstructorBuildTests: XCTestCase {

    // MARK: - columnBoundaries (x-center clustering)

    /// Columns come from the x-center distribution, so a row that spans a
    /// would-be gutter no longer suppresses the table (the empty-band approach
    /// failed on real documents). A spanning token at 0.30 just forms its own
    /// middle column instead of zeroing out column detection for the whole table.
    func test_columnBoundaries_clustersXCenters_toleratesSpanningToken() {
        let tokens = [
            tok("a", midX: 0.10, midY: 0.10), tok("b", midX: 0.50, midY: 0.10),
            tok("c", midX: 0.10, midY: 0.20), tok("d", midX: 0.50, midY: 0.20),
            tok("title", midX: 0.30, midY: 0.30),   // spans the gutter
        ]
        let cuts = TableReconstructor.columnBoundaries(tokens, minSeparation: 0.12)
        // 0.10,0.10,0.30,0.50,0.50 → gaps 0,0.20,0.20,0 → cuts at 0.20 and 0.40
        XCTAssertEqual(cuts.count, 2)
        XCTAssertEqual(cuts[0], 0.20, accuracy: 0.001)
        XCTAssertEqual(cuts[1], 0.40, accuracy: 0.001)
    }

    func test_columnBoundaries_singleColumn_noCuts() {
        let tokens = [tok("a", midX: 0.5, midY: 0.1), tok("b", midX: 0.5, midY: 0.2)]
        XCTAssertEqual(TableReconstructor.columnBoundaries(tokens, minSeparation: 0.10), [])
    }

    // MARK: - Helpers

    /// Token whose midX = x + w/2 and midY = y + h/2.
    private func tok(_ text: String, midX: CGFloat, midY: CGFloat) -> LayoutToken {
        let w: CGFloat = 0.06
        let h: CGFloat = 0.03
        return LayoutToken(text: text, rect: CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h))
    }

    // MARK: - Two-region table

    /// Layout (normalised coordinates):
    ///
    ///   LEFT REGION (midX ∈ 0.05..0.25)    RIGHT REGION (midX ∈ 0.65..0.85)
    ///   ──────────────────────────────       ──────────────────────────────────
    ///   row 0 (y ≈ 0.10):  "Name"  "Age"    "City"  "Code"
    ///   row 1 (y ≈ 0.25):  "Alice"  "30"    "Paris"  "75"
    ///   row 2 (y ≈ 0.40):  "Bob"    "25"    "Rome"   "00"
    ///
    /// Wide gap (≈ 0.33 wide) in x ∈ [0.28, 0.62] separates the two regions.
    /// Within each region a gap of ≈ 0.14 separates col 0 from col 1.
    func test_buildTables_twoRegions_returnsTwoStructuredTables() {
        // --- LEFT region ---
        let leftTokens: [LayoutToken] = [
            // row 0 — headers
            tok("Name",  midX: 0.05, midY: 0.10),
            tok("Age",   midX: 0.22, midY: 0.10),
            // row 1
            tok("Alice", midX: 0.05, midY: 0.25),
            tok("30",    midX: 0.22, midY: 0.25),
            // row 2
            tok("Bob",   midX: 0.05, midY: 0.40),
            tok("25",    midX: 0.22, midY: 0.40),
        ]

        // --- RIGHT region ---
        let rightTokens: [LayoutToken] = [
            // row 0 — headers
            tok("City",  midX: 0.65, midY: 0.10),
            tok("Code",  midX: 0.82, midY: 0.10),
            // row 1
            tok("Paris", midX: 0.65, midY: 0.25),
            tok("75",    midX: 0.82, midY: 0.25),
            // row 2
            tok("Rome",  midX: 0.65, midY: 0.40),
            tok("00",    midX: 0.82, midY: 0.40),
        ]

        let allTokens = leftTokens + rightTokens

        // splitRegions needs a gap wide enough (> minGap) between regions
        // and each region needs an intra-column gap also >= minGap.
        // We use minGap = 0.10, tolerance = 0.05.
        let tables = TableReconstructor.buildTables(allTokens, tolerance: 0.05, minGap: 0.10, columnSeparation: 0.10)

        XCTAssertEqual(tables.count, 2, "Expected two tables (one per region)")

        // Tables are returned in region order (left region first).
        let leftTable  = tables[0]
        let rightTable = tables[1]

        XCTAssertEqual(leftTable.headers, ["Name", "Age"])
        XCTAssertEqual(leftTable.rows, [["Alice", "30"], ["Bob", "25"]])

        XCTAssertEqual(rightTable.headers, ["City", "Code"])
        XCTAssertEqual(rightTable.rows, [["Paris", "75"], ["Rome", "00"]])
    }

    // MARK: - Prose paragraph (single column) → no table

    /// Tokens stacked vertically, all in a single column — prose, not a table.
    /// Fewer than 2 columns → must be dropped.
    func test_buildTables_singleColumnProse_returnsEmpty() {
        let tokens: [LayoutToken] = [
            tok("The",    midX: 0.50, midY: 0.10),
            tok("quick",  midX: 0.50, midY: 0.20),
            tok("brown",  midX: 0.50, midY: 0.30),
            tok("fox",    midX: 0.50, midY: 0.40),
        ]
        let tables = TableReconstructor.buildTables(tokens, tolerance: 0.03, minGap: 0.10, columnSeparation: 0.10)
        XCTAssertEqual(tables, [], "Single-column prose must produce no table")
    }

    // MARK: - Single row → no table

    /// Only one row present — not enough rows to have headers + at least one data row.
    func test_buildTables_singleRow_returnsEmpty() {
        let tokens: [LayoutToken] = [
            tok("A", midX: 0.10, midY: 0.50),
            tok("B", midX: 0.60, midY: 0.50),
        ]
        let tables = TableReconstructor.buildTables(tokens, tolerance: 0.03, minGap: 0.10, columnSeparation: 0.10)
        XCTAssertEqual(tables, [], "Single row must produce no table (need headers + at least 1 data row)")
    }

    // MARK: - Empty input

    func test_buildTables_emptyInput_returnsEmpty() {
        let tables = TableReconstructor.buildTables([], tolerance: 0.05, minGap: 0.10, columnSeparation: 0.10)
        XCTAssertEqual(tables, [])
    }
}
