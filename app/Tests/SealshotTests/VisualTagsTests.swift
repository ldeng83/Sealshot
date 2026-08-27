import XCTest
@testable import Sealshot

final class VisualTagsTests: XCTestCase {

    func testAtCapturePutsStructuralBeforeGeneratedBeforeScene() {
        let visual = VisualTags(structural: ["qr-code"], scene: ["photo"])
        let merged = VisualTagMerge.atCapture(generated: ["error", "github"], visual: visual)
        // structural first, then generated, then scene
        XCTAssertEqual(merged, ["qr-code", "error", "github", "photo"])
    }

    func testAtCaptureDedupesAndNormalizes() {
        let visual = VisualTags(structural: ["QR Code"], scene: [])
        let merged = VisualTagMerge.atCapture(generated: ["qr-code"], visual: visual)
        XCTAssertEqual(merged, ["qr-code"])   // normalized + deduped
    }

    func testCapKeepsStructuralDropsScene() {
        // 8 generated text tags already at the cap; scene must be the one dropped,
        // structural must survive by being ordered first.
        let generated = ["a","b","c","d","e","f","g","h"]
        let visual = VisualTags(structural: ["qr-code"], scene: ["photo"])
        let merged = VisualTagMerge.atCapture(generated: generated, visual: visual)
        XCTAssertEqual(merged.count, 8)
        XCTAssertTrue(merged.contains("qr-code"))     // structural kept
        XCTAssertFalse(merged.contains("photo"))      // scene dropped
        XCTAssertFalse(merged.contains("h"))          // lowest generated dropped after structural inserted
    }

    func testBackfillKeepsExistingFirstThenAppendsVisual() {
        // existing may contain user tags; they must come first and never be dropped.
        let merged = VisualTagMerge.backfill(existing: ["my-tag", "error"],
                                             visual: VisualTags(structural: ["document"], scene: ["photo"]))
        XCTAssertEqual(merged, ["my-tag", "error", "document", "photo"])
    }

    func testBackfillNeverDropsExistingWhenAtCap() {
        let existing = ["u1","u2","u3","u4","u5","u6","u7","u8"]
        let merged = VisualTagMerge.backfill(existing: existing,
                                             visual: VisualTags(structural: ["qr-code"], scene: []))
        XCTAssertEqual(merged, existing)   // existing preserved, visual dropped at cap
    }
}
