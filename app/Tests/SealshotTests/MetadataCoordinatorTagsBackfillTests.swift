import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class MetadataCoordinatorTagsBackfillTests: XCTestCase {

    private func img() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// A tagless .seal that already has a summary, sourceApp, favorite, and OCR.
    private func taglessSeal() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCT-\(UUID().uuidString).seal")
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let meta = CaptureMetadata(generatedTitle: "", userTitle: nil, tags: [],
                                   category: .other, confidence: 0, generatorVersion: 2,
                                   visualTagVersion: 3, summary: "Existing summary.")
        try SealMetadataStore.apply(metadata: meta, sourceApp: "Safari",
                                    ocrText: "Payment failed. Card declined.", to: url)
        try SealMetadataStore.setWorkflow(isFavorite: true, to: url)
        return url
    }

    private struct StubGen: MetadataGenerating {
        let keywords: [String]
        func makeMetadata(for signals: MetadataSignals) async -> CaptureMetadata {
            CaptureMetadata(generatedTitle: "Gen Title", userTitle: nil, tags: [],
                            smartKeywords: keywords,
                            category: .other, confidence: 1, generatorVersion: 2)
        }
    }

    func test_generateTags_writesSmartKeywords_preservesOtherFields_postsChange() async throws {
        let url = try taglessSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = MetadataCoordinator(metadataGenerator: { StubGen(keywords: ["alpha", "beta"]) })

        let changed = expectation(forNotification: .captureMetadataDidChange, object: nil)
        await coordinator.generateTags(for: url, packageKey: nil)
        await fulfillment(of: [changed], timeout: 2)

        let m = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(m.metadata?.smartKeywords, ["alpha", "beta"], "smartKeywords backfilled")
        XCTAssertTrue(m.metadata?.tags.isEmpty ?? false, "user tags stay empty after auto-backfill")
        XCTAssertEqual(m.metadata?.summary, "Existing summary.", "summary preserved")
        XCTAssertEqual(m.metadata?.visualTagVersion, 3, "visual tag version preserved")
        XCTAssertEqual(m.sourceApp, "Safari", "sourceApp preserved")
        XCTAssertEqual(m.isFavorite, true, "favorite preserved")
    }

    /// Regression: turning on on-device AI must NOT wipe user-added tags. AI
    /// off → user adds tags → AI on → the first keyword backfill runs on a
    /// capture that already has user tags. Generators emit `tags: []`, so
    /// without the carry-over the regenerated struct clobbered every user tag.
    func test_generateTags_preservesUserTags() async throws {
        let url = try taglessSeal(); defer { try? FileManager.default.removeItem(at: url) }
        // Simulate tags added while AI was off (smartKeywords still empty, so the
        // backfill gate still fires).
        try SealMetadataStore.update(at: url) { $0.tags = ["payment", "urgent"] }
        let coordinator = MetadataCoordinator(metadataGenerator: { StubGen(keywords: ["alpha", "beta"]) })

        await coordinator.generateTags(for: url, packageKey: nil)

        let m = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(m.metadata?.tags, ["payment", "urgent"], "user tags survive keyword backfill")
        XCTAssertEqual(m.metadata?.smartKeywords, ["alpha", "beta"], "smartKeywords still backfilled")
    }

    func test_generateTags_noOpWhenSmartKeywordsAlreadyPresent() async throws {
        let url = try taglessSeal(); defer { try? FileManager.default.removeItem(at: url) }
        // Give it smartKeywords first — gate fires on smartKeywords.isEmpty, not tags.isEmpty.
        try SealMetadataStore.update(at: url) { $0.smartKeywords = ["kept"] }
        let coordinator = MetadataCoordinator(metadataGenerator: { StubGen(keywords: ["new"]) })
        // A no-op must NOT announce a change: posting on the skip path re-arms
        // the editor's backfill check — with an unreadable manifest that cycle
        // never terminated (main-thread livelock: capture while locked →
        // unlock → notify → sync → ensure → skip → notify …). The progress
        // bar clears via the stage channel + registry, not this notification.
        let changed = expectation(forNotification: .captureMetadataDidChange, object: nil)
        changed.isInverted = true
        await coordinator.generateTags(for: url, packageKey: nil)
        await fulfillment(of: [changed], timeout: 0.3)
        let m = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(m.metadata?.smartKeywords, ["kept"], "existing smartKeywords must not be overwritten")
    }

    /// The livelock regression (capture while locked → unlock → app pegged):
    /// an UNREADABLE manifest must not arm the backfill, and a generation
    /// that could write nothing must not announce a metadata change.
    func test_unreadableManifest_doesNotArmOrAnnounce() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCT-unreadable-\(UUID().uuidString).seal")
        let coordinator = MetadataCoordinator(metadataGenerator: { StubGen(keywords: ["x"]) })

        let started = expectation(forNotification: .captureNameGenerationStarted, object: nil)
        started.isInverted = true
        let changed = expectation(forNotification: .captureMetadataDidChange, object: nil)
        changed.isInverted = true

        coordinator.ensureTags(for: url)
        await coordinator.generateTags(for: url, packageKey: nil)

        await fulfillment(of: [started, changed], timeout: 0.3)
        XCTAssertFalse(NameGenerationRegistry.shared.contains(url),
                       "unreadable package must not be marked in-flight")
    }
}

/// Pure-image captures (no readable text) must be TERMINAL for the keyword
/// backfill: OCR ran and found nothing (`ocrText == ""`, the v4 marker), so
/// re-running can never produce text keywords — without the gate, every
/// metadata-change notification re-armed the backfill and the "Generating
/// keywords…" bar looped forever.
final class TagBackfillGateTests: XCTestCase {

    func test_keywordsPresent_noBackfill() {
        XCTAssertFalse(MetadataCoordinator.needsTagBackfill(
            smartKeywordsEmpty: false, ocrText: "some text"))
    }

    func test_keywordsEmpty_withText_backfills() {
        XCTAssertTrue(MetadataCoordinator.needsTagBackfill(
            smartKeywordsEmpty: true, ocrText: "invoice total 42"))
    }

    func test_keywordsEmpty_neverOCRd_backfills() {
        // nil = OCR never ran (pre-v4 package) — backfill runs it.
        XCTAssertTrue(MetadataCoordinator.needsTagBackfill(
            smartKeywordsEmpty: true, ocrText: nil))
    }

    func test_keywordsEmpty_ocrRanAndFoundNothing_isTerminal() {
        // "" = OCR ran, image has no text (pure image) — never re-run.
        XCTAssertFalse(MetadataCoordinator.needsTagBackfill(
            smartKeywordsEmpty: true, ocrText: ""))
    }
}
