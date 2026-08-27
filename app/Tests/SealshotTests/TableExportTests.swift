import XCTest
@testable import Sealshot

final class TableExportTests: XCTestCase {

    // MARK: - CSV

    func test_csv_simpleGrid() {
        let t = StructuredTable(headers: ["Name", "Age"], rows: [["Alice", "30"], ["Bob", "25"]])
        XCTAssertEqual(TableExport.csv(t), "Name,Age\r\nAlice,30\r\nBob,25")
    }

    func test_csv_fieldWithComma_isQuoted() {
        let t = StructuredTable(headers: ["City"], rows: [["Portland, OR"]])
        XCTAssertEqual(TableExport.csv(t), "City\r\n\"Portland, OR\"")
    }

    func test_csv_fieldWithQuote_doublesQuote() {
        let t = StructuredTable(headers: ["Q"], rows: [["she said \"hi\""]])
        XCTAssertEqual(TableExport.csv(t), "Q\r\n\"she said \"\"hi\"\"\"")
    }

    func test_csv_fieldWithNewline_isQuoted() {
        let t = StructuredTable(headers: ["A"], rows: [["line1\nline2"]])
        XCTAssertEqual(TableExport.csv(t), "A\r\n\"line1\nline2\"")
    }

    func test_csv_headersOnly_emitsHeaderLine() {
        let t = StructuredTable(headers: ["A", "B"], rows: [])
        XCTAssertEqual(TableExport.csv(t), "A,B")
    }

    func test_csv_raggedRow_paddedToHeaderCount() {
        let t = StructuredTable(headers: ["A", "B", "C"], rows: [["1", "2"]])
        XCTAssertEqual(TableExport.csv(t), "A,B,C\r\n1,2,")
    }

    func test_csv_overlongRow_truncatedToHeaderCount() {
        let t = StructuredTable(headers: ["A", "B"], rows: [["1", "2", "3"]])
        XCTAssertEqual(TableExport.csv(t), "A,B\r\n1,2")
    }

    // MARK: - TSV

    func test_tsv_simpleGrid() {
        let t = StructuredTable(headers: ["Name", "Age"], rows: [["Alice", "30"]])
        XCTAssertEqual(TableExport.tsv(t), "Name\tAge\nAlice\t30")
    }

    func test_tsv_cellWithTab_replacedWithSpace() {
        let t = StructuredTable(headers: ["A"], rows: [["x\ty"]])
        XCTAssertEqual(TableExport.tsv(t), "A\nx y")
    }

    func test_tsv_cellWithNewline_replacedWithSpace() {
        let t = StructuredTable(headers: ["A"], rows: [["x\ny"]])
        XCTAssertEqual(TableExport.tsv(t), "A\nx y")
    }

    func test_tsv_raggedRow_paddedToHeaderCount() {
        let t = StructuredTable(headers: ["A", "B"], rows: [["1"]])
        XCTAssertEqual(TableExport.tsv(t), "A\tB\n1\t")
    }
}
