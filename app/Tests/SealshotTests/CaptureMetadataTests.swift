import XCTest
@testable import Sealshot

final class CaptureMetadataTests: XCTestCase {

    private func make(generated: String, user: String?) -> CaptureMetadata {
        CaptureMetadata(generatedTitle: generated, userTitle: user, tags: ["a"],
                        category: .error, confidence: 0.5, generatorVersion: 1)
    }

    func testDisplayTitle_prefersUserTitle() {
        let m = make(generated: "Auto Title", user: "My Title")
        XCTAssertEqual(m.displayTitle(fallback: "file.seal"), "My Title")
    }

    func testDisplayTitle_fallsBackToGenerated_whenNoUserTitle() {
        let m = make(generated: "Auto Title", user: nil)
        XCTAssertEqual(m.displayTitle(fallback: "file.seal"), "Auto Title")
    }

    func testDisplayTitle_fallsBackToFilename_whenGeneratedEmpty() {
        let m = make(generated: "", user: nil)
        XCTAssertEqual(m.displayTitle(fallback: "file.seal"), "file.seal")
    }

    func testDisplayTitle_treatsWhitespaceOnlyUserTitleAsAbsent() {
        let m = make(generated: "Auto Title", user: "   \n")
        XCTAssertEqual(m.displayTitle(fallback: "file.seal"), "Auto Title")
    }

    func testCodableRoundTrip() throws {
        let m = make(generated: "Auto Title", user: "Edited")
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(CaptureMetadata.self, from: data)
        XCTAssertEqual(m, back)
    }

    func testDecodesLegacyManifestWithoutVisualTagVersion() throws {
        // A manifest written before visual tagging existed: no visualTagVersion key.
        // Also predates v11 split, so old `tags` migrate to smartKeywords; user tags = [].
        let json = """
        {"generatedTitle":"X","userTitle":null,"tags":["error"],
         "category":"error","confidence":0.5,"generatorVersion":2}
        """.data(using: .utf8)!
        let meta = try JSONDecoder().decode(CaptureMetadata.self, from: json)
        XCTAssertEqual(meta.visualTagVersion, 0)
        XCTAssertEqual(meta.smartKeywords, ["error"])
        XCTAssertEqual(meta.tags, [])
    }

    func testRoundTripsVisualTagVersion() throws {
        let meta = CaptureMetadata(generatedTitle: "X", userTitle: nil, tags: ["photo"],
                                   category: .other, confidence: 0.5, generatorVersion: 2,
                                   visualTagVersion: 1)
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(CaptureMetadata.self, from: data)
        XCTAssertEqual(back.visualTagVersion, 1)
    }

    // MARK: - smartKeywords migration tests (Task 1)

    func test_decode_preSplitManifest_movesTagsToSmartKeywords() throws {
        // A pre-split manifest has `tags` but no `smartKeywords` key.
        let json = """
        {"generatedTitle":"t","userTitle":null,"tags":["login","error"],
         "category":"other","confidence":0.5,"generatorVersion":1}
        """.data(using: .utf8)!
        let meta = try JSONDecoder().decode(CaptureMetadata.self, from: json)
        XCTAssertEqual(meta.smartKeywords, ["login", "error"])
        XCTAssertEqual(meta.tags, [])
    }

    func test_decode_v11Manifest_keepsBothFieldsIndependent() throws {
        let json = """
        {"generatedTitle":"t","userTitle":null,"tags":["mine"],"smartKeywords":["auto"],
         "category":"other","confidence":0.5,"generatorVersion":1}
        """.data(using: .utf8)!
        let meta = try JSONDecoder().decode(CaptureMetadata.self, from: json)
        XCTAssertEqual(meta.smartKeywords, ["auto"])
        XCTAssertEqual(meta.tags, ["mine"])
    }

    func test_encode_then_decode_roundTripsSmartKeywords() throws {
        let m = CaptureMetadata(generatedTitle: "t", userTitle: nil, tags: ["mine"],
                                smartKeywords: ["auto"], category: .other,
                                confidence: 0.5, generatorVersion: 1)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(CaptureMetadata.self, from: data)
        XCTAssertEqual(back, m)
    }
}
