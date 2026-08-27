import XCTest
@testable import Sealshot

/// The legacy JSON index (now read once for SQLite migration) and the shared
/// manifest→entry reader used by `LibraryIndexStore.reconcile`.
@MainActor
final class LibrarySearchIndexTests: XCTestCase {

    private func entry(mtime: Date, title: String = "", tags: [String] = [],
                       ocr: String = "", captureDate: Date? = nil) -> CaptureSearchText {
        CaptureSearchText(mtime: mtime, title: title, tags: tags, ocrText: ocr,
                          captureDate: captureDate, userTitle: nil)
    }
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/shots/\(name)")
    }
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: load/save

    func testSaveAndLoad_roundTrips() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID().uuidString)/searchIndex.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let index = LibrarySearchIndex(fileURL: file)
        let entries = ["k": entry(mtime: t0, title: "T", tags: ["a"], ocr: "body")]
        index.save(entries)
        XCTAssertEqual(index.load(), entries)
    }

    func testLoad_missingOrCorrupt_returnsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("searchIndex.json")

        XCTAssertEqual(LibrarySearchIndex(fileURL: file).load(), [:])   // missing
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(LibrarySearchIndex(fileURL: file).load(), [:])   // corrupt
    }

    // MARK: production reader

    func testReadEntry_fromSealManifest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let img = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        try writeSealPackage(to: dir, source: img, composite: img, annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let meta = CaptureMetadata(generatedTitle: "Login Page", userTitle: nil, tags: ["web"],
                                   category: .other, confidence: 0.5, generatorVersion: 1)
        try SealMetadataStore.apply(metadata: meta, sourceApp: nil, ocrText: "Sign in\nEmail", to: dir)

        let e = LibrarySearchIndex.readEntry(at: dir, mtime: t0)
        XCTAssertEqual(e?.title, "Login Page")
        XCTAssertEqual(e?.tags, ["web"])
        XCTAssertEqual(e?.ocrText, "Sign in\nEmail")
        XCTAssertEqual(e?.mtime, t0)
    }

    func testReadEntry_nonSeal_returnsNil() {
        XCTAssertNil(LibrarySearchIndex.readEntry(at: url("x.png"), mtime: t0))
    }

    // MARK: v2 fields (captureDate + userTitle)

    func testDecode_legacyJSONWithoutV2Fields_yieldsNilCaptureDate() throws {
        // An entry persisted before captureDate/userTitle existed — the
        // SQLite migration skips these (nil captureDate) so reconcile
        // re-reads their manifests once instead of importing bad dates.
        let legacy = """
        {"mtime": 700000000, "title": "t", "tags": ["a"], "ocrText": "x"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaptureSearchText.self, from: legacy)
        XCTAssertNil(decoded.captureDate)
        XCTAssertNil(decoded.userTitle)
        XCTAssertEqual(decoded.title, "t")
        // v4 (favorite/status) keys are also absent here. They MUST stay
        // optional: synthesized Codable calls `decode` (which throws on a
        // missing key) for non-optionals, so a non-optional field would make
        // this whole legacy entry — and `load()`'s whole-map decode — throw,
        // silently discarding the migration index. Optional → nil, resolved at
        // the use site.
        XCTAssertNil(decoded.isFavorite)
        XCTAssertNil(decoded.status)
        // v5 (captureKind/durationSeconds) also absent — MUST stay optional or
        // the whole-map decode in load() would throw and silently discard the
        // migration index.
        XCTAssertNil(decoded.captureKind)
        XCTAssertNil(decoded.durationSeconds)
    }

    // MARK: v5 fields (captureKind + durationSeconds)

    func testReadEntry_videoSeal_populatesCaptureKindAndDuration() throws {
        // Build a video .seal via VideoSealPackageIO.write with a manifest carrying
        // captureKind=.screenRecording + VideoInfo(durationSeconds:).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a minimal payload file (required by VideoSealPackageIO.write).
        let tempPayload = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-\(UUID().uuidString).mov")
        try Data("fake video data".utf8).write(to: tempPayload)

        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-24T10:00:00Z",
            modifiedISO8601: "2026-06-24T10:00:00Z",
            sourceSize: SealManifest.Size(width: 1920, height: 1080),
            sourceApp: nil,
            captureKind: .screenRecording,
            video: VideoInfo(durationSeconds: 42.5, hasAudio: true))

        try VideoSealPackageIO.write(
            to: dir,
            payloadTempURL: tempPayload,
            originalUTI: "com.apple.quicktime-movie",
            manifest: manifest,
            thumbnailPNG: nil,
            crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        let entry = try XCTUnwrap(LibrarySearchIndex.readEntry(at: dir, mtime: t0))
        XCTAssertEqual(entry.captureKind, .screenRecording)
        XCTAssertEqual(try XCTUnwrap(entry.durationSeconds), 42.5, accuracy: 0.001)
    }

    func testReadEntry_populatesCaptureDateAndUserTitle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-v2-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let img = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        try writeSealPackage(to: dir, source: img, composite: img, annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let meta = CaptureMetadata(generatedTitle: "", userTitle: "My Title", tags: ["alpha"],
                                   category: .other, confidence: 0.5, generatorVersion: 1)
        try SealMetadataStore.apply(metadata: meta, sourceApp: nil, to: dir)

        let entry = try XCTUnwrap(LibrarySearchIndex.readEntry(at: dir, mtime: t0))
        XCTAssertEqual(entry.userTitle, "My Title")
        let created = try XCTUnwrap(entry.captureDate)
        // createdISO8601 was written moments ago.
        XCTAssertLessThan(abs(created.timeIntervalSinceNow), 60)
    }
}
