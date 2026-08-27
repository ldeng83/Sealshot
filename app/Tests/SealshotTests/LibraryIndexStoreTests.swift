import XCTest
@testable import Sealshot

@MainActor
final class LibraryIndexStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryIndexStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSeal(in dir: URL, named name: String,
                          userTitle: String? = nil, ocr: String? = nil) throws -> URL {
        let seal = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        try writeSealPackage(to: seal, source: img, composite: img,
                             annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        if userTitle != nil || ocr != nil {
            let meta = CaptureMetadata(generatedTitle: "", userTitle: userTitle,
                                       tags: [], category: .other,
                                       confidence: 0, generatorVersion: 1)
            try SealMetadataStore.apply(metadata: meta, sourceApp: nil,
                                        ocrText: ocr, to: seal)
        }
        return seal
    }

    private func makeStore(_ dir: URL) -> LibraryIndexStore {
        LibraryIndexStore(
            databaseURL: dir.appendingPathComponent("db/index.sqlite"),
            legacyIndex: LibrarySearchIndex(
                fileURL: dir.appendingPathComponent("legacy/idx.json")))
    }

    func test_items_listsCaptures_withDisplayNames() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        _ = try makeSeal(in: shots, named: "a.seal", userTitle: "Renamed")
        _ = try makeSeal(in: shots, named: "b.seal")

        let store = makeStore(dir)
        let items = await store.items(section: .allFiles, saveFolder: shots,
                                      search: "", now: Date())
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.displayName == "Renamed" })
        XCTAssertTrue(items.contains { $0.displayName == "b" })
    }

    func test_allMembers_returnsEveryCapture_forWholeLibraryExport() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        _ = try makeSeal(in: shots, named: "a.seal", userTitle: "Alpha")
        _ = try makeSeal(in: shots, named: "b.seal")
        _ = try makeSeal(in: shots, named: "c.seal")

        let store = makeStore(dir)
        let members = await store.allMembers(saveFolder: shots)

        // Every capture is returned, regardless of collection/favorite membership
        // (no filter) — the whole-library "Export All Files" source set.
        XCTAssertEqual(members.count, 3)
        XCTAssertEqual(Set(members.map(\.displayName)), ["Alpha", "b", "c"])
    }

    func test_items_searchHitsOCR_withSnippet() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        _ = try makeSeal(in: shots, named: "a.seal", ocr: "unique zebra crossing")
        _ = try makeSeal(in: shots, named: "b.seal", ocr: "nothing here")

        let store = makeStore(dir)
        let items = await store.items(section: .allFiles, saveFolder: shots,
                                      search: "zebra", now: Date())
        XCTAssertEqual(items.count, 1)
        XCTAssertNotNil(items[0].matchSnippet)
    }

    func test_reconcile_prunesDeletedFiles() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let a = try makeSeal(in: shots, named: "a.seal")
        let store = makeStore(dir)
        _ = await store.items(section: .allFiles, saveFolder: shots, search: "", now: Date())

        try FileManager.default.removeItem(at: a)
        let items = await store.items(section: .allFiles, saveFolder: shots,
                                      search: "", now: Date())
        XCTAssertTrue(items.isEmpty)
    }

    func test_reconcile_picksUpMetadataChanges() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let seal = try makeSeal(in: shots, named: "a.seal")
        let store = makeStore(dir)
        _ = await store.items(section: .allFiles, saveFolder: shots, search: "", now: Date())

        let meta = CaptureMetadata(generatedTitle: "", userTitle: "Edited Title",
                                   tags: [], category: .other,
                                   confidence: 0, generatorVersion: 1)
        try SealMetadataStore.apply(metadata: meta, sourceApp: nil, to: seal)
        // Writing manifest.json updates the entry file but the package
        // DIRECTORY mtime must change for stat-level freshness; touch it the
        // way the app's atomic re-save does.
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: seal.path)

        let items = await store.items(section: .allFiles, saveFolder: shots,
                                      search: "", now: Date())
        XCTAssertEqual(items.first?.displayName, "Edited Title")
    }

    func test_legacyJSONIndex_isMigratedOnce_thenDeleted() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = LibrarySearchIndex(
            fileURL: dir.appendingPathComponent("legacy/idx.json"))
        let mtime = Date(timeIntervalSince1970: 1_000)
        legacy.save(["/gone/x.seal": CaptureSearchText(
            mtime: mtime, title: "t", tags: ["tag"], ocrText: "legacy words",
            captureDate: mtime, userTitle: "Old")])

        let store = LibraryIndexStore(
            databaseURL: dir.appendingPathComponent("db/index.sqlite"),
            legacyIndex: legacy)
        // Any call opens the DB and triggers migration.
        _ = await store.items(section: .allFiles,
                              saveFolder: dir.appendingPathComponent("empty"),
                              search: "", now: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.fileURL.path),
                       "legacy JSON must be deleted after import")
    }

    func test_trashSection_readsDeletedSubfolder() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        let trash = shots.appendingPathComponent(SealDeleter.deletedSubfolderName)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        _ = try makeSeal(in: trash, named: "binned.seal")

        let store = makeStore(dir)
        let all = await store.items(section: .allFiles, saveFolder: shots,
                                    search: "", now: Date())
        let binned = await store.items(section: .trash, saveFolder: shots,
                                       search: "", now: Date())
        XCTAssertTrue(all.isEmpty)
        XCTAssertEqual(binned.count, 1)
    }

    func test_allTags_userTagMatchingSmartKeywordStillListed() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        // One capture carries "test" as an AUTO smart keyword…
        let auto = try makeSeal(in: shots, named: "auto.seal")
        try SealMetadataStore.apply(metadata: CaptureMetadata(
            generatedTitle: "", userTitle: nil, tags: [], smartKeywords: ["test"],
            category: .other, confidence: 0, generatorVersion: 1),
            sourceApp: nil, to: auto)
        // …and the user hand-tags ANOTHER capture with the same word.
        let tagged = try makeSeal(in: shots, named: "tagged.seal")
        try SealMetadataStore.update(at: tagged, createIfMissing: true) { $0.tags = ["test"] }

        let store = makeStore(dir)
        _ = await store.items(section: .allFiles, saveFolder: shots,
                              search: "", now: Date())
        let tags = await store.allTags()
        XCTAssertEqual(tags.first { $0.tag == "test" }?.count, 1,
                       "a user tag must appear in BY TAG even when the same word is an auto keyword elsewhere")
    }

    func test_legacyPNG_isIndexedByStat() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shots = dir.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: shots.appendingPathComponent("legacy.png"))

        let store = makeStore(dir)
        let items = await store.items(section: .allFiles, saveFolder: shots,
                                      search: "", now: Date())
        XCTAssertEqual(items.map(\.displayName), ["legacy"])

        let byName = await store.items(section: .allFiles, saveFolder: shots,
                                       search: "lega", now: Date())
        XCTAssertEqual(byName.count, 1)
    }

    /// Set a .seal package's manifest capture date.
    private func setCreated(_ seal: URL, daysAgo: Double) throws {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(sealEntryData("manifest.json", at: seal))) as? [String: Any])
        obj["createdISO8601"] = ISO8601DateFormatter()
            .string(from: Date().addingTimeInterval(-daysAgo * 86_400))
        try SealContainer.rewritingManifest(
            try JSONSerialization.data(withJSONObject: obj), in: seal)
    }

    func test_deletedStrip_ordersByDeleteTimeNotCaptureDate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trash = dir.appendingPathComponent(SealDeleter.deletedSubfolderName)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        // "old" was captured long ago but deleted just now (newest mtime);
        // "new" was captured recently but deleted earlier (older mtime). By
        // capture date the order would be ["new","old"]; by delete time it's
        // ["old","new"] — which is what the Deleted strip should show.
        let oldCapture = try makeSeal(in: trash, named: "old.seal")
        try setCreated(oldCapture, daysAgo: 30)
        let newCapture = try makeSeal(in: trash, named: "new.seal")
        try setCreated(newCapture, daysAgo: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: newCapture.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: oldCapture.path)

        let store = makeStore(dir)
        let items = await store.stripItems(folder: trash, recordingsFolder: nil,
                                           coveringDays: 30, now: Date())
        XCTAssertEqual(items?.map { $0.url.lastPathComponent }, ["old.seal", "new.seal"])
    }

    func test_stripItems_oldCapturesStillListed_dayWindow() async throws {
        // The strip's window is "the most recent days WITH captures", not
        // calendar days back from now — a library whose newest capture is a
        // month old must still fill the strip.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seal = try makeSeal(in: dir, named: "old.seal")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(sealEntryData("manifest.json", at: seal))) as? [String: Any])
        obj["createdISO8601"] = ISO8601DateFormatter()
            .string(from: Date().addingTimeInterval(-30 * 86_400))
        try SealContainer.rewritingManifest(
            try JSONSerialization.data(withJSONObject: obj), in: seal)

        let store = makeStore(dir)
        let items = await store.stripItems(folder: dir, recordingsFolder: nil, coveringDays: 7, now: Date())
        XCTAssertEqual(items?.map { $0.url.lastPathComponent }, ["old.seal"])
    }

    // MARK: - Index-change notification

    func test_reconcile_postsDidChange_whenItIndexesACapture() async throws {
        // Without this signal nothing tells the recent strip that a background
        // reconcile has filled a previously-empty index, so the strip keeps
        // rendering the stale empty listing until some unrelated event (or an
        // app restart) happens to refresh it.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeSeal(in: dir, named: "a.seal")

        let posted = expectation(description: "libraryIndexDidChange posted")
        let token = NotificationCenter.default.addObserver(
            forName: .libraryIndexDidChange, object: nil, queue: nil
        ) { _ in posted.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        await makeStore(dir).reconcile(folder: dir)
        await fulfillment(of: [posted], timeout: 5)
    }

    func test_reconcile_doesNotPostDidChange_whenNothingChanged() async throws {
        // A no-op reconcile must stay silent, or every pass would re-refresh
        // every strip for nothing.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeSeal(in: dir, named: "a.seal")
        let store = makeStore(dir)
        await store.reconcile(folder: dir)   // first pass indexes it

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .libraryIndexDidChange, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        await store.reconcile(folder: dir)   // second pass has nothing to do
        XCTAssertEqual(posts, 0, "an unchanged reconcile must not post")
    }

    func test_reconcile_doesNotPostRepeatedly_forAnUnreadableManifest() async throws {
        // A `.seal` whose manifest can't be read is re-read on EVERY reconcile:
        // its row keeps the fileSize == 0 "re-read me" sentinel, so it never
        // hits the fast-path skip and always marks the pass as changed. If the
        // notification followed that flag, each post would drive a strip
        // refresh, which reconciles again, which posts again — an endless
        // refresh loop for any capture the session can't read. Only a
        // MEMBERSHIP change (rows added or removed) may post.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seal = try makeSeal(in: dir, named: "a.seal")
        // Drop the manifest entry — an unreadable package, the case this test
        // is about. (A tail rewrite with nil removes it from the container.)
        try SealContainer.rewritingTail(["manifest.json": nil], in: seal)

        let store = makeStore(dir)
        await store.reconcile(folder: dir)   // indexes it provisionally

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .libraryIndexDidChange, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        await store.reconcile(folder: dir)
        await store.reconcile(folder: dir)
        XCTAssertEqual(posts, 0,
                       "re-reading an already-listed capture must not re-post")
    }
}
