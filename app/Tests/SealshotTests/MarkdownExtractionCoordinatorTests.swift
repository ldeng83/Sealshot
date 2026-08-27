import XCTest
@testable import Sealshot

@MainActor
final class MarkdownExtractionCoordinatorTests: XCTestCase {

    private func itemsWithEmail() -> StructuredItems {
        var i = StructuredItems()
        i.emails = ["a@b.com"]
        return i
    }

    func test_baselineWhenFMUnavailable() async {
        let c = MarkdownExtractionCoordinator(composeFM: nil)   // FM off
        let md = await c.markdown(items: itemsWithEmail(), ocrText: "a@b.com")
        XCTAssertTrue(md.contains("a@b.com"))
        XCTAssertTrue(md.contains("## Emails"), "expected deterministic baseline sections; got \(md)")
    }

    func test_usesFMWhenAvailable() async {
        let c = MarkdownExtractionCoordinator(composeFM: { _, _, _ in "# Polished\n- a@b.com" })
        let md = await c.markdown(items: itemsWithEmail(), ocrText: "a@b.com")
        XCTAssertEqual(md, "# Polished\n- a@b.com")
    }

    func test_fallsBackWhenFMReturnsNil() async {
        let c = MarkdownExtractionCoordinator(composeFM: { _, _, _ in nil })
        let md = await c.markdown(items: itemsWithEmail(), ocrText: "a@b.com")
        XCTAssertTrue(md.contains("## Emails"), "FM nil → baseline; got \(md)")
    }

    func test_hasTableFlag_reflectsExtractedTables() async {
        var hasTableSeen: Bool?
        let c = MarkdownExtractionCoordinator(composeFM: { _, _, hasTable in
            hasTableSeen = hasTable; return "ok"
        })
        _ = await c.markdown(items: itemsWithEmail(), ocrText: "a@b.com")
        XCTAssertEqual(hasTableSeen, false, "no table extracted → hasTable false")

        var withTable = StructuredItems()
        withTable.tables = [StructuredTable(headers: ["A", "B"], rows: [["1", "2"]])]
        _ = await c.markdown(items: withTable, ocrText: "")
        XCTAssertEqual(hasTableSeen, true, "table extracted → hasTable true")
    }

    func test_noItemsFallsBackToOCRText() async {
        let c = MarkdownExtractionCoordinator(composeFM: nil)
        let md = await c.markdown(items: StructuredItems(), ocrText: "raw screen text")
        XCTAssertTrue(md.contains("raw screen text"))
    }
}
