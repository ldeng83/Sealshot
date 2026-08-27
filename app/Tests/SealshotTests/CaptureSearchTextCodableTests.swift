import XCTest
@testable import Sealshot

final class CaptureSearchTextCodableTests: XCTestCase {
    // Legacy JSON written before width/height/sourceApp existed must still
    // decode (fields resolve to nil), or the migration index is discarded.
    func testDecodesLegacyJSONWithoutDimensionKeys() throws {
        let legacy = """
        {"mtime": 0, "title": "t", "tags": [], "ocrText": ""}
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(CaptureSearchText.self, from: legacy)
        XCTAssertNil(entry.width)
        XCTAssertNil(entry.height)
        XCTAssertNil(entry.sourceApp)
    }

    func testRoundTripsNewFields() throws {
        let e = CaptureSearchText(mtime: Date(timeIntervalSince1970: 0),
                                  title: "t", tags: [], ocrText: "",
                                  width: 1920, height: 1080, sourceApp: "Figma")
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(CaptureSearchText.self, from: data)
        XCTAssertEqual(back.width, 1920)
        XCTAssertEqual(back.height, 1080)
        XCTAssertEqual(back.sourceApp, "Figma")
    }
}
