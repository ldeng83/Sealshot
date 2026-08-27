import XCTest
@testable import Sealshot

final class CaptureMetadataSummaryTests: XCTestCase {
    private func base() -> CaptureMetadata {
        CaptureMetadata(generatedTitle: "t", userTitle: nil, tags: [],
                        category: .other, confidence: 1, generatorVersion: 1)
    }

    func test_summaryRoundTrips() throws {
        var m = base(); m.summary = "A login screen."; m.summaryVersion = 1
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(CaptureMetadata.self, from: data)
        XCTAssertEqual(back.summary, "A login screen.")
        XCTAssertEqual(back.summaryVersion, 1)
    }

    func test_defaultsWhenAbsent() throws {
        var m = base(); m.summary = nil
        XCTAssertNil(m.summary)
        XCTAssertEqual(m.summaryVersion, 0)
    }

    func test_decodesOldManifestWithoutSummaryKeys() throws {
        // JSON written before this feature has neither key.
        let json = """
        {"generatedTitle":"t","tags":[],"category":"other","confidence":1.0,
         "generatorVersion":1,"visualTagVersion":0}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(CaptureMetadata.self, from: json)
        XCTAssertNil(m.summary)
        XCTAssertEqual(m.summaryVersion, 0)
    }

    // MARK: - userSummary three states (v13)

    func test_effectiveSummary_nilOverride_showsGenerated() {
        var m = base(); m.summary = "Generated."; m.userSummary = nil
        XCTAssertEqual(m.effectiveSummary, "Generated.")
        XCTAssertFalse(m.hasUserSummaryOverride)
    }

    func test_effectiveSummary_textOverride_wins() {
        var m = base(); m.summary = "Generated."; m.userSummary = "Mine."
        XCTAssertEqual(m.effectiveSummary, "Mine.")
        XCTAssertTrue(m.hasUserSummaryOverride)
    }

    func test_effectiveSummary_emptyOverride_isSuppressedBlank_notGenerated() {
        // The bug: an emptied summary must stay blank, not revert to generated.
        var m = base(); m.summary = "Generated."; m.userSummary = ""
        XCTAssertEqual(m.effectiveSummary, "", "suppressed summary stays blank")
        XCTAssertTrue(m.hasUserSummaryOverride, "suppression counts as an override")
    }

    func test_suppressedSummary_blocksRegeneration() {
        // userSummaryPresent must be true for a suppressed summary so it isn't
        // regenerated and repopulated.
        var m = base(); m.summary = nil; m.userSummary = ""
        XCTAssertFalse(SummaryGating.shouldGenerate(
            aiEnabled: true, foundationModelAvailable: true, summaryPresent: false,
            ocrText: "lots of text here", userSummaryPresent: m.hasUserSummaryOverride))
    }

    func test_emptyOverrideRoundTrips() throws {
        var m = base(); m.summary = "Generated."; m.userSummary = ""
        let back = try JSONDecoder().decode(CaptureMetadata.self,
                                            from: JSONEncoder().encode(m))
        XCTAssertEqual(back.userSummary, "")
        XCTAssertEqual(back.effectiveSummary, "")
    }
}
