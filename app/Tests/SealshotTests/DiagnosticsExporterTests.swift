import XCTest
@testable import Sealshot

final class DiagnosticsExporterTests: XCTestCase {

    private func entry(_ seconds: TimeInterval, category: String = "library",
                       level: String = "info", message: String = "hello")
        -> DiagnosticsExporter.Entry {
        DiagnosticsExporter.Entry(
            date: Date(timeIntervalSince1970: seconds),
            category: category, level: level, message: message)
    }

    func test_format_lineShape() {
        let text = DiagnosticsExporter.format(
            entries: [entry(0, category: "capture", level: "error", message: "boom")],
            limit: 10)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("Sealshot diagnostics"),
                      "header identifies the file: \(lines[0])")
        XCTAssertTrue(lines.last!.hasSuffix("[capture] error boom"),
                      "entry line carries category/level/message: \(lines.last!)")
    }

    func test_format_capsAtLimit_keepingMostRecent() {
        let entries = (0..<50).map { entry(TimeInterval($0), message: "m\($0)") }
        let text = DiagnosticsExporter.format(entries: entries, limit: 10)
        XCTAssertFalse(text.contains(" m39\n") || text.hasSuffix("m39"))
        XCTAssertTrue(text.contains("m40"), "cap keeps the most recent entries")
        XCTAssertTrue(text.contains("m49"))
        XCTAssertTrue(text.contains("(showing most recent 10 of 50 entries)"))
    }

    func test_format_empty_isHeaderOnly() {
        let text = DiagnosticsExporter.format(entries: [], limit: 10)
        XCTAssertTrue(text.hasPrefix("Sealshot diagnostics"))
        XCTAssertTrue(text.contains("(no entries)"))
    }

    func test_exportFile_writesReadableText() throws {
        let url = try DiagnosticsExporter.exportFile(
            entries: [entry(1, message: "exported line")])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Sealshot-diagnostics-"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("exported line"))
    }
}
