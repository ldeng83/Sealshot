import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class SealMetadataStoreTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-\(UUID().uuidString).seal")
    }
    private func img() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func meta(_ title: String) -> CaptureMetadata {
        CaptureMetadata(generatedTitle: title, userTitle: nil, tags: ["t"],
                        category: .error, confidence: 0.6, generatorVersion: 1)
    }

    /// Build a minimal `.seal` directory whose manifest holds `meta` (+ optional
    /// `VideoInfo`). Mirrors `writeSealPackage` at the manifest layer only.
    private func makeSealStore(meta: CaptureMetadata, video: VideoInfo? = nil) throws -> URL {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-01-01T00:00:00Z",
            modifiedISO8601: "2026-01-01T00:00:00Z",
            sourceSize: SealManifest.Size(width: 4, height: 4),
            sourceApp: nil,
            metadata: meta,
            video: video)
        try manifest.encodeJSON()
            .write(to: url.appendingPathComponent("manifest.json"))
        return url
    }

    /// The metadata-undo seam: `update` reports pre/post to the hook so the
    /// editor can mint ⌘Z checkpoints for user edits (title/summary/tags).
    func test_update_firesDidUpdateMetadataHook() throws {
        let url = try makeSealStore(meta: meta("Auto"))
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = SealMetadataStore.didUpdateMetadata
        defer { SealMetadataStore.didUpdateMetadata = saved }

        var fired: (URL, CaptureMetadata?, CaptureMetadata)?
        SealMetadataStore.didUpdateMetadata = { fired = ($0, $1, $2) }
        try SealMetadataStore.update(at: url) { $0.tags = ["t", "new"] }

        XCTAssertEqual(fired?.0, url)
        XCTAssertEqual(fired?.1?.tags, ["t"], "pre-edit metadata")
        XCTAssertEqual(fired?.2.tags, ["t", "new"], "post-edit metadata")

        // The no-op guard path (missing metadata, no createIfMissing) stays silent.
        fired = nil
        let bare = tempURL()
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        try SealManifest(version: SealManifest.currentVersion,
                         createdISO8601: "2026-01-01T00:00:00Z",
                         modifiedISO8601: "2026-01-01T00:00:00Z",
                         sourceSize: SealManifest.Size(width: 4, height: 4),
                         sourceApp: nil, metadata: nil, video: nil)
            .encodeJSON().write(to: bare.appendingPathComponent("manifest.json"))
        try SealMetadataStore.update(at: bare) { $0.tags = ["x"] }
        XCTAssertNil(fired, "early-return update must not report")
    }

    func testApplyAndRead() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.apply(metadata: meta("Hello"), sourceApp: "Safari", to: url)
        let read = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(read.manifest.metadata, meta("Hello"))
        XCTAssertEqual(read.manifest.sourceApp, "Safari")
    }

    func testUpdate_mutatesExisting() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.apply(metadata: meta("Auto"), sourceApp: nil, to: url)
        try SealMetadataStore.update(at: url) { $0.userTitle = "Edited" }
        let read = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(read.manifest.metadata?.userTitle, "Edited")
        XCTAssertEqual(read.manifest.metadata?.generatedTitle, "Auto") // generated untouched
    }

    func testApply_missingPackage_throws() {
        let url = tempURL() // never created
        XCTAssertThrowsError(try SealMetadataStore.apply(metadata: meta("X"), sourceApp: nil, to: url))
    }

    func testApply_bumpsModifiedKeepsCreated() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let before = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)).manifest
        try SealMetadataStore.apply(metadata: meta("X"), sourceApp: nil, to: url)
        let after = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)).manifest
        XCTAssertEqual(after.createdISO8601, before.createdISO8601)
        XCTAssertGreaterThanOrEqual(after.modifiedISO8601, before.modifiedISO8601)
    }

    // MARK: - smartKeywords threading (Task 2)

    func test_update_changingTags_preservesSmartKeywords() throws {
        let url = try makeSealStore(meta: CaptureMetadata(
            generatedTitle: "t", userTitle: nil, tags: [],
            smartKeywords: ["auto1", "auto2"], category: .other,
            confidence: 1, generatorVersion: 1))
        defer { try? FileManager.default.removeItem(at: url) }
        try SealMetadataStore.update(at: url) { $0.tags = ["userTag"] }
        let meta = try SealMetadataStore.readManifest(at: url).metadata!
        XCTAssertEqual(meta.tags, ["userTag"])
        XCTAssertEqual(meta.smartKeywords, ["auto1", "auto2"])  // preserved
    }

    func test_setWorkflow_preservesSmartKeywords() throws {
        let url = try makeSealStore(meta: CaptureMetadata(
            generatedTitle: "t", userTitle: nil, tags: [],
            smartKeywords: ["auto"], category: .other,
            confidence: 1, generatorVersion: 1))
        defer { try? FileManager.default.removeItem(at: url) }
        try SealMetadataStore.setWorkflow(isFavorite: true, status: .reviewed, to: url)
        let meta = try SealMetadataStore.readManifest(at: url).metadata!
        XCTAssertEqual(meta.smartKeywords, ["auto"])
    }

    // MARK: - v13: editable summary (userSummary override)

    func test_v13Fields_decodeDefaultsOnOldManifests() throws {
        // A pre-v13 manifest (no userSummary key) loads with the neutral default.
        let url = try makeSealStore(meta: meta("Old"))
        defer { try? FileManager.default.removeItem(at: url) }
        let m = try XCTUnwrap(SealMetadataStore.readManifest(at: url).metadata)
        XCTAssertNil(m.userSummary)
    }

    func test_v13Fields_roundTripThroughUpdate() throws {
        let url = try makeSealStore(meta: meta("X"))
        defer { try? FileManager.default.removeItem(at: url) }
        try SealMetadataStore.update(at: url) {
            $0.userSummary = "My own words."
        }
        let m = try XCTUnwrap(SealMetadataStore.readManifest(at: url).metadata)
        XCTAssertEqual(m.userSummary, "My own words.")
    }

    func test_effectiveSummary_overrideWinsElseGenerated() {
        var m = CaptureMetadata(generatedTitle: "", userTitle: nil, tags: [],
                                category: .other, confidence: 0, generatorVersion: 0)
        XCTAssertNil(m.effectiveSummary)
        m.summary = "generated"
        XCTAssertEqual(m.effectiveSummary, "generated")
        m.userSummary = "   "
        XCTAssertEqual(m.effectiveSummary, "", "blank override wins — a deliberately emptied summary stays blank, not generated")
        m.userSummary = "mine"
        XCTAssertEqual(m.effectiveSummary, "mine")
    }

    // MARK: - update with no metadata (AI off: manual tags/rename must work)

    func test_update_missingMetadata_noOpByDefault() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.update(at: url) { $0.tags = ["dropped"] }
        XCTAssertNil(try SealMetadataStore.readManifest(at: url).metadata)
    }

    func test_update_createIfMissing_startsFromUserEditableShell() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        try SealMetadataStore.update(at: url, createIfMissing: true) { $0.tags.append("alpha") }
        let meta = try XCTUnwrap(SealMetadataStore.readManifest(at: url).metadata)
        XCTAssertEqual(meta.tags, ["alpha"])
        // The shell must not fake generator output: later AI backfill keys off
        // empty smartKeywords / generatorVersion 0.
        XCTAssertEqual(meta.generatedTitle, "")
        XCTAssertNil(meta.userTitle)
        XCTAssertEqual(meta.smartKeywords, [])
        XCTAssertEqual(meta.generatorVersion, 0)
    }

    func test_update_createIfMissing_existingMetadataUntouched() throws {
        let url = try makeSealStore(meta: CaptureMetadata(
            generatedTitle: "Auto", userTitle: nil, tags: ["old"],
            smartKeywords: ["kw"], category: .error,
            confidence: 0.6, generatorVersion: 2))
        defer { try? FileManager.default.removeItem(at: url) }
        try SealMetadataStore.update(at: url, createIfMissing: true) { $0.tags.append("new") }
        let meta = try XCTUnwrap(SealMetadataStore.readManifest(at: url).metadata)
        XCTAssertEqual(meta.tags, ["old", "new"])
        XCTAssertEqual(meta.generatedTitle, "Auto")      // existing metadata kept
        XCTAssertEqual(meta.smartKeywords, ["kw"])
        XCTAssertEqual(meta.generatorVersion, 2)
    }

    func test_setVideoTags_writesSmartKeywords_notTags() throws {
        let url = try makeSealStore(
            meta: CaptureMetadata(
                generatedTitle: "t", userTitle: nil, tags: ["keepUser"],
                smartKeywords: [], category: .other,
                confidence: 1, generatorVersion: 1),
            video: VideoInfo(durationSeconds: 5, hasAudio: false))
        defer { try? FileManager.default.removeItem(at: url) }
        try SealMetadataStore.setVideoTags(["k1", "k2"], version: 1, to: url)
        let meta = try SealMetadataStore.readManifest(at: url).metadata!
        XCTAssertEqual(meta.smartKeywords, ["k1", "k2"])
        XCTAssertEqual(meta.tags, ["keepUser"])  // user tags untouched
    }
}
