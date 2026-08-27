import XCTest
@testable import Sealshot

@MainActor
final class VisualTagBackfillTests: XCTestCase {

    private func meta(version: Int) -> CaptureMetadata {
        CaptureMetadata(generatedTitle: "T", userTitle: nil, tags: ["user-tag"],
                        category: .other, confidence: 0.5, generatorVersion: 2,
                        visualTagVersion: version)
    }

    func testNeedsTaggingWhenVersionStale() {
        XCTAssertTrue(VisualTagBackfillJob.needsTagging(metadata: meta(version: 0), isLocked: false))
    }

    func testSkipsWhenAlreadyCurrentVersion() {
        XCTAssertFalse(VisualTagBackfillJob.needsTagging(
            metadata: meta(version: VisionTagger.version), isLocked: false))
    }

    func testSkipsWhenNoMetadata() {
        XCTAssertFalse(VisualTagBackfillJob.needsTagging(metadata: nil, isLocked: false))
    }

    func testSkipsWhenLocked() {
        XCTAssertFalse(VisualTagBackfillJob.needsTagging(metadata: meta(version: 0), isLocked: true))
    }

    func testBackfillUpdateIsAdditiveAndPreservesUserTags() throws {
        // Build a plaintext .seal with metadata (reuse the helper from
        // SealMetadataStoreTests — same temp-package construction).
        let url = try TestSealFactory.makePlaintextSeal(
            metadata: meta(version: 0))   // tags == ["user-tag"]
        defer { try? FileManager.default.removeItem(at: url) }

        try SealMetadataStore.update(at: url) {
            $0.tags = VisualTagMerge.backfill(existing: $0.tags,
                visual: VisualTags(structural: ["qr-code"], scene: []))
            $0.visualTagVersion = VisionTagger.version
        }

        let back = try SealMetadataStore.readManifest(at: url).metadata
        XCTAssertEqual(back?.tags, ["user-tag", "qr-code"])      // user tag preserved, additive
        XCTAssertEqual(back?.visualTagVersion, VisionTagger.version)
    }
}
