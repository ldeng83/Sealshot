import XCTest
@testable import Sealshot

@MainActor
final class StripItemsTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StripItemsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve canonical path (e.g. /var → /private/var on macOS) so
        // URLs built from this directory compare equal to
        // contentsOfDirectory-sourced URLs.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(dir.path, &buf) != nil {
            return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
        }
        return dir
    }

    private func makeSeal(in dir: URL, named name: String,
                          userTitle: String? = nil) throws -> URL {
        let seal = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        try writeSealPackage(to: seal, source: img, composite: img,
                             annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        if let userTitle {
            let meta = CaptureMetadata(generatedTitle: "", userTitle: userTitle,
                                       tags: [], category: .other,
                                       confidence: 0, generatorVersion: 1)
            try SealMetadataStore.apply(metadata: meta, sourceApp: nil,
                                        ocrText: nil, to: seal)
        }
        return seal
    }

    private func makeStore(_ dir: URL) -> LibraryIndexStore {
        LibraryIndexStore(
            databaseURL: dir.appendingPathComponent("db/index.sqlite"),
            legacyIndex: LibrarySearchIndex(
                fileURL: dir.appendingPathComponent("legacy/idx.json")))
    }

    /// A video `.seal` (recording) indexed in the save folder must surface in the
    /// strip as a VIDEO item (play/duration affordance + Videos media-filter
    /// bucket) — derived from the manifest's captureKind, the same as the Library.
    private func makeVideoSeal(in dir: URL, named name: String) throws -> URL {
        let seal = dir.appendingPathComponent(name)
        let payload = dir.appendingPathComponent("payload-\(UUID().uuidString).mov")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: payload)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-24T00:00:00Z", modifiedISO8601: "2026-06-24T00:00:00Z",
            sourceSize: .init(width: 1920, height: 1080), sourceApp: nil,
            captureKind: .screenRecording,
            video: VideoInfo(durationSeconds: 5.0, hasAudio: true))
        try VideoSealPackageIO.write(to: seal, payloadTempURL: payload, originalUTI: "public.mpeg-4",
                                     manifest: manifest, thumbnailPNG: nil,
                                     crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        return seal
    }

    func test_stripItems_videoSeal_isMarkedVideo() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        _ = try makeVideoSeal(in: shots, named: "rec.seal")
        _ = try makeSeal(in: shots, named: "shot.seal")
        let store = makeStore(dir)
        let result = await store.stripItems(folder: shots, recordingsFolder: nil,
                                            coveringDays: 7, now: Date())
        let items = try XCTUnwrap(result)
        let rec = try XCTUnwrap(items.first { $0.url.lastPathComponent == "rec.seal" })
        let shot = try XCTUnwrap(items.first { $0.url.lastPathComponent == "shot.seal" })
        XCTAssertTrue(rec.isVideo, "a screenRecording .seal must be a video strip item")
        XCTAssertFalse(shot.isVideo, "an image .seal must not be a video strip item")
    }

    /// A video `.seal`'s duration lives in its manifest (VideoInfo) and is
    /// indexed (CaptureIndexRow.durationSeconds). The strip must carry it on the
    /// StripItem so the tile can draw the "m:ss" badge directly — an AVURLAsset
    /// can't read a `.seal` package, so the async loader fallback yields nothing.
    func test_stripItems_videoSeal_carriesDuration() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        _ = try makeVideoSeal(in: shots, named: "rec.seal")
        _ = try makeSeal(in: shots, named: "shot.seal")
        let store = makeStore(dir)
        let result = await store.stripItems(folder: shots, recordingsFolder: nil,
                                            coveringDays: 7, now: Date())
        let items = try XCTUnwrap(result)
        let rec = try XCTUnwrap(items.first { $0.url.lastPathComponent == "rec.seal" })
        let shot = try XCTUnwrap(items.first { $0.url.lastPathComponent == "shot.seal" })
        XCTAssertEqual(rec.durationSeconds, 5.0,
                       "a video .seal strip item must carry the indexed duration")
        XCTAssertNil(shot.durationSeconds, "an image .seal must have no duration")
    }

    func test_stripItems_listsNewestFirst_withDisplayNames() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        _ = try makeSeal(in: shots, named: "older.seal", userTitle: "Renamed")
        // Distinct capture dates: the second package is created strictly later.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = try makeSeal(in: shots, named: "newer.seal")

        let store = makeStore(dir)
        let items = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: Date())
        XCTAssertEqual(items?.map(\.displayName), ["newer", "Renamed"])
    }

    func test_stripItems_oldCapture_staysInWindow() async throws {
        // The window is the most recent days WITH captures, not calendar
        // days back from now — viewed 8 days later, a lone capture is still
        // listed rather than blanking the strip.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        _ = try makeSeal(in: shots, named: "a.seal")
        let store = makeStore(dir)

        let nowItems = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: Date())
        XCTAssertEqual(nowItems?.count, 1)
        let future = Date().addingTimeInterval(8 * 86_400)
        let futureItems = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: future)
        XCTAssertEqual(futureItems?.count, 1)
    }

    func test_stripItems_isolatesFolders_recentVsDeleted() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        let deleted = shots.appendingPathComponent("Deleted")
        try FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
        _ = try makeSeal(in: shots, named: "live.seal")
        _ = try makeSeal(in: deleted, named: "gone.seal")

        let store = makeStore(dir)
        let recent = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: Date())
        let trash = await store.stripItems(folder: deleted, recordingsFolder: nil, coveringDays: 30, now: Date())
        XCTAssertEqual(recent?.map(\.displayName), ["live"])
        XCTAssertEqual(trash?.map(\.displayName), ["gone"])
    }

    func test_stripItems_reconciles_newAndRemovedFiles() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let a = try makeSeal(in: shots, named: "a.seal")
        let store = makeStore(dir)
        _ = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: Date())

        try FileManager.default.removeItem(at: a)
        _ = try makeSeal(in: shots, named: "b.seal")
        let items = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: Date())
        XCTAssertEqual(items?.map(\.displayName), ["b"])
    }

    func test_stripItems_returnsNil_whenDatabaseUnopenable() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        // databaseURL nested under a regular FILE → open fails both times.
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let store = LibraryIndexStore(
            databaseURL: blocker.appendingPathComponent("nested/index.sqlite"),
            legacyIndex: LibrarySearchIndex(
                fileURL: dir.appendingPathComponent("legacy/idx.json")))
        let items = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: Date())
        XCTAssertNil(items)
    }

    func test_stripItems_emptyFolder_returnsEmptyNotNil() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let store = makeStore(dir)
        let items = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: Date())
        XCTAssertEqual(items, [])
    }

    /// Contract test: StripItem URLs must compare equal to the directory-form
    /// URLs the tiles/selection/Show-in-Library use. NOTE this cannot
    /// distinguish the explicit `isDirectory:` hint from Foundation's
    /// auto-detection (which stats existing paths and yields the same URL) —
    /// the explicit hint in stripItems is kept for the stat-per-URL cost and
    /// the deleted-mid-query race, not because this test would fail without
    /// it. The equality contract itself is what's locked here.
    func test_stripItems_sealURLs_areFileForm_equalToDirectoryListing() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        _ = try makeSeal(in: shots, named: "a.seal")

        let store = makeStore(dir)
        let items = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: Date())
        XCTAssertEqual(items?.first?.url.hasDirectoryPath, false,
                       ".seal StripItem URLs must be file-form (single-file container)")
        // Normalize listed URLs through standardizedFileURL to match the
        // store's path normalization (reconcile stores standardizedFileURL.path).
        let listed = try FileManager.default.contentsOfDirectory(
            at: shots, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "a.seal" }
            .map { $0.standardizedFileURL }
        XCTAssertEqual(items?.map(\.url), listed,
                       "StripItem URLs must compare equal to directory-listing URLs")
    }

    // MARK: Recency — an opened capture joins the strip like any other

    /// A minimal `.seal` carrying a chosen capture date, so a test can build a
    /// library whose oldest items fall outside the strip's day window.
    private func makeDatedSeal(in dir: URL, named name: String, created: Date) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let stamp = ISO8601DateFormatter().string(from: created)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: stamp, modifiedISO8601: stamp,
            sourceSize: .init(width: 4, height: 4), sourceApp: nil,
            showingEnhanced: false, metadata: nil)
        try SealContainer.write(entries: [("manifest.json", try manifest.encodeJSON())], to: url)
        return url
    }

    /// Nine capture days so the 7-day window genuinely excludes the oldest —
    /// the shape of the reported library, where an Aug 22 capture sat 11 days
    /// back. Returns the out-of-window URL.
    private func makeLibraryWithAnOldCapture(in shots: URL, now: Date) throws -> URL {
        for day in 1...8 {
            _ = try makeDatedSeal(in: shots, named: "day\(day).seal",
                                  created: now.addingTimeInterval(-Double(day) * 86_400))
        }
        return try makeDatedSeal(in: shots, named: "old.seal",
                                 created: now.addingTimeInterval(-30 * 86_400))
    }

    /// The reported bug: an old capture opened from the Library used to be
    /// PINNED to slot 0 for the whole session, so every screenshot taken
    /// afterwards was pushed behind it. It must instead enter the listing on its
    /// own recency — present, and first only until something newer arrives.
    func test_stripItems_openedOldCapture_joinsTheListing() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let now = Date()
        let old = try makeLibraryWithAnOldCapture(in: shots, now: now)
        let store = makeStore(dir)

        let beforeItems = await store.stripItems(
            folder: shots, recordingsFolder: nil, coveringDays: 7, now: now)
        let before = try XCTUnwrap(beforeItems)
        XCTAssertFalse(before.contains { $0.url.lastPathComponent == "old.seal" },
                       "30 days back is outside the 7-day window")

        // A second back, not exactly `now` — see `test_markActivity_survivesReconcile`
        // for why stamping at the query instant is unstable.
        let openedAt = now.addingTimeInterval(-1)
        await store.markActivity(url: old, at: openedAt)

        let afterItems = await store.stripItems(
            folder: shots, recordingsFolder: nil, coveringDays: 7, now: now)
        let after = try XCTUnwrap(afterItems)
        let item = try XCTUnwrap(after.first { $0.url.lastPathComponent == "old.seal" },
                                 "opening it must bring it into the strip")
        XCTAssertEqual(item.captureDate.timeIntervalSince1970,
                       openedAt.timeIntervalSince1970, accuracy: 0.5,
                       "it is ordered by when it was opened")
        XCTAssertEqual(after.first?.url.lastPathComponent, "old.seal",
                       "nothing newer exists yet, so it leads")
    }

    /// The other half of the same complaint: a screenshot taken AFTER opening an
    /// old capture must land in front of it. Under pinning it landed behind.
    func test_stripItems_captureTakenAfterAnOpen_sortsAhead() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let now = Date()
        let old = try makeLibraryWithAnOldCapture(in: shots, now: now)
        let store = makeStore(dir)

        // Opened an hour ago, then a fresh capture right now.
        await store.markActivity(url: old, at: now.addingTimeInterval(-3600))
        _ = try makeDatedSeal(in: shots, named: "fresh.seal", created: now)

        let listed = await store.stripItems(
            folder: shots, recordingsFolder: nil, coveringDays: 7, now: now)
        let items = try XCTUnwrap(listed)
        let freshIndex = try XCTUnwrap(items.firstIndex { $0.url.lastPathComponent == "fresh.seal" })
        let oldIndex = try XCTUnwrap(items.firstIndex { $0.url == old },
                                     "the opened capture stays listed")
        XCTAssertLessThan(freshIndex, oldIndex,
                          "a capture taken after the open must sort ahead of it — "
                          + "the pinned tile used to force the opposite")
    }

    /// The stamp lives in the index and the reconcile upsert does not list its
    /// column — so re-indexing (every strip refresh reconciles) must not wipe it.
    func test_markActivity_survivesReconcile() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let now = Date()
        let old = try makeLibraryWithAnOldCapture(in: shots, now: now)
        let store = makeStore(dir)

        // A second earlier, not exactly `now`: a real open is always followed by a
        // refresh that samples its own `Date()`. Stamping at the very instant
        // later passed as `now` is not merely unrealistic, it is unstable —
        // `Date` counts from 2001, so a value stored and re-read through
        // `timeIntervalSince1970` can come back 1 ULP LARGER than the original,
        // and `StripItem.merged` drops anything dated after `now` as clock skew.
        // That dropped the capture from the listing outright, at random.
        await store.markActivity(url: old, at: now.addingTimeInterval(-1))
        // A wide window so this test is about the STAMP surviving, not about
        // window membership — each stripItems call reconciles the folder first.
        _ = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 30, now: now)
        let listed = await store.stripItems(
            folder: shots, recordingsFolder: nil, coveringDays: 30, now: now)
        let items = try XCTUnwrap(listed)
        let item = try XCTUnwrap(items.first { $0.url.lastPathComponent == "old.seal" })
        XCTAssertEqual(item.captureDate.timeIntervalSince1970,
                       now.addingTimeInterval(-1).timeIntervalSince1970, accuracy: 0.5,
                       "two reconciles later the strip must still order this by the stamp, "
                       + "not fall back to its 30-day-old capture date")
    }

    /// Opening must never write the capture itself — a view that dirties a
    /// package makes backups re-copy it and turns "Modified" into "last opened".
    func test_markActivity_doesNotTouchTheFile() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let now = Date()
        let old = try makeLibraryWithAnOldCapture(in: shots, now: now)
        let store = makeStore(dir)
        _ = await store.stripItems(folder: shots, recordingsFolder: nil, coveringDays: 7, now: now)
        let before = try FileManager.default.attributesOfItem(atPath: old.path)[.modificationDate] as? Date

        await store.markActivity(url: old, at: now)

        let after = try FileManager.default.attributesOfItem(atPath: old.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "the package's mtime must be untouched by an open")
    }
}
