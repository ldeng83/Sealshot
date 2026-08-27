import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class SealMigratorTests: XCTestCase {
    let identity = IdentityKey.generate()
    lazy var gen = KeyGeneration.make(publicKey: identity.publicKey)
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Deleted"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func makePlainPackage(named name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? folder).appendingPathComponent("\(name).seal", isDirectory: false)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-11T00:00:00Z", modifiedISO8601: "2026-06-11T00:00:00Z",
            sourceSize: .init(width: 4, height: 4), sourceApp: nil,
            showingEnhanced: false, metadata: nil, ocrText: "find-me")
        try SealContainer.write(entries: [
            ("source.png", Data([1, 2, 3])),
            ("manifest.json", try manifest.encodeJSON()),
        ], to: url)
        return url
    }

    func testEncryptAllSealsEveryPackageIncludingDeleted() async throws {
        let a = try makePlainPackage(named: "a")
        let d = try makePlainPackage(named: "gone",
                                     in: folder.appendingPathComponent("Deleted"))
        var progress: [Int] = []
        let count = try await SealMigrator.encryptAll(
            in: folder, publicKey: identity.publicKey, generation: gen) { done, _ in progress.append(done) }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(SealPackageCrypter.isLocked(a))
        XCTAssertTrue(SealPackageCrypter.isLocked(d))
        XCTAssertEqual(progress.last, 2)
        // Entries genuinely sealed
        XCTAssertTrue(SealedBlob.isSealed(try XCTUnwrap(sealEntryData("manifest.json", at: a))))
    }

    func testEncryptAllIsIdempotent() async throws {
        _ = try makePlainPackage(named: "a")
        _ = try await SealMigrator.encryptAll(in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        let second = try await SealMigrator.encryptAll(in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        XCTAssertEqual(second, 0) // already locked → skipped (this IS the resume mechanism)
    }

    func testEncryptPreservesMtime() async throws {
        let a = try makePlainPackage(named: "a")
        let before = try FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as! Date
        _ = try await SealMigrator.encryptAll(in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        let after = try FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as! Date
        XCTAssertEqual(before.timeIntervalSince1970, after.timeIntervalSince1970, accuracy: 1.0)
    }

    func testDecryptAllRestoresPlaintextRoundTrip() async throws {
        let a = try makePlainPackage(named: "a")
        let original = try XCTUnwrap(sealEntryData("manifest.json", at: a))
        _ = try await SealMigrator.encryptAll(in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        let outcome = await SealMigrator.decryptAll(in: folder, keyFor: { _ in identity }) { _, _ in }
        XCTAssertEqual(outcome.decrypted, 1)
        XCTAssertTrue(outcome.unrecoverable.isEmpty)
        XCTAssertFalse(SealPackageCrypter.isLocked(a))
        XCTAssertEqual(try XCTUnwrap(sealEntryData("manifest.json", at: a)), original)
    }

    /// A plaintext package with a streaming video `payload` (raw movie bytes,
    /// several KB so content equality is meaningful).
    private func makePlainVideoPackage(named name: String) throws -> (url: URL, payload: Data) {
        let url = try makePlainPackage(named: name)
        var payload = Data("ftypqt  fake movie bytes ".utf8)
        payload.append(Data((0..<4096).map { UInt8($0 % 251) }))
        // Rebuild the container with the payload as an entry — a payload is
        // not a tail entry, so it cannot be appended in place.
        var entries = try SealContainer.Reader(url: url).allEntries()
        entries[SealMigrator.videoPayloadEntry] = payload
        try SealContainer.write(entries: entries.map { ($0.key, $0.value) }, to: url)
        return (url, payload)
    }

    func testEncryptAllChunkEncryptsVideoPayload() async throws {
        let (a, original) = try makePlainVideoPackage(named: "vid")
        _ = try await SealMigrator.encryptAll(
            in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        XCTAssertTrue(SealPackageCrypter.isLocked(a))
        // The payload is a container ENTRY; stream it out to check it and to
        // hand the player's own reader a real file.
        let payloadURL = folder.appendingPathComponent("payload-check.bin")
        try SealContainer.Reader(url: a).extract(SealMigrator.videoPayloadEntry, to: payloadURL)
        XCTAssertEqual(try Data(contentsOf: payloadURL).prefix(4), SealedChunkFile.magic,
                       "payload must be the chunked container the player expects, not a SealedBlob")
        // And it round-trips through the player's own reader with the package CEK.
        let lock = try JSONDecoder().decode(
            LockHeader.self, from: try XCTUnwrap(sealEntryData("lock.json", at: a)))
        let cek = try SealPackageCrypter.unwrapCEK(lock, identity: identity)
        let out = folder.appendingPathComponent("plain.mov")
        try SealedChunkFile.decryptWhole(payloadURL, to: out, key: cek)
        XCTAssertEqual(try Data(contentsOf: out), original)
    }

    /// THE video-loss regression: turning encryption off must decrypt video
    /// packages (chunked payload) instead of reporting them unrecoverable —
    /// the blob-only path quarantined every video in the library.
    func testDecryptAllRoundTripsVideoPackage() async throws {
        let (a, original) = try makePlainVideoPackage(named: "vid")
        _ = try await SealMigrator.encryptAll(
            in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        let outcome = await SealMigrator.decryptAll(in: folder, keyFor: { _ in identity }) { _, _ in }
        XCTAssertEqual(outcome.decrypted, 1)
        XCTAssertTrue(outcome.unrecoverable.isEmpty,
                      "a healthy video package must never be quarantined")
        XCTAssertFalse(SealPackageCrypter.isLocked(a))
        let restored = folder.appendingPathComponent("restored.bin")
        try SealContainer.Reader(url: a).extract(SealMigrator.videoPayloadEntry, to: restored)
        XCTAssertEqual(try Data(contentsOf: restored),
                       original, "payload restored to the raw movie bytes")
    }

    func testDecryptAllAcrossGenerationsQuarantinesUnreachable() async throws {
        // Package A is sealed under generation/identity gen; package B under a
        // second, unrelated generation whose key we will NOT supply.
        let a = try makePlainPackage(named: "a")
        _ = try await SealMigrator.encryptAll(in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }

        let other = IdentityKey.generate()
        let otherGen = KeyGeneration.make(publicKey: other.publicKey)
        let b = try makePlainPackage(named: "b")
        let manifestB = try XCTUnwrap(sealEntryData("manifest.json", at: b))
        let (sealedB, _) = try SealPackageCrypter.sealEntries(
            ["manifest.json": manifestB], publicKey: other.publicKey, generation: otherGen)
        try SealContainer.write(entries: sealedB.map { ($0.key, $0.value) }, to: b)

        // Resolver knows only `gen` → A decrypts, B is unrecoverable.
        let outcome = await SealMigrator.decryptAll(
            in: folder, keyFor: { $0 == gen.id ? identity : nil }) { _, _ in }

        XCTAssertEqual(outcome.decrypted, 1)
        XCTAssertEqual(outcome.unrecoverable, [b])
        XCTAssertFalse(SealPackageCrypter.isLocked(a), "reachable generation decrypted")
        XCTAssertTrue(SealPackageCrypter.isLocked(b), "unreachable generation left locked")
    }

    func testRekeyAllRewrapsLidAndLeavesDataUntouched() async throws {
        let a = try makePlainPackage(named: "a")
        _ = try await SealMigrator.encryptAll(in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        let dataBefore = try XCTUnwrap(sealEntryData("manifest.json", at: a))

        let newIdentity = IdentityKey.generate()
        let newGen = KeyGeneration.make(publicKey: newIdentity.publicKey)
        let outcome = await SealMigrator.rekeyAll(
            in: folder, old: identity, new: newIdentity.publicKey, generation: newGen)

        XCTAssertEqual(outcome.rekeyed, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
        // The sealed data entry is byte-identical — only the lid changed.
        XCTAssertEqual(try XCTUnwrap(sealEntryData("manifest.json", at: a)), dataBefore)
        let header = try JSONDecoder().decode(
            LockHeader.self, from: try XCTUnwrap(sealEntryData("lock.json", at: a)))
        XCTAssertEqual(header.capsule.generationID, newGen.id)
        XCTAssertNoThrow(try SealPackageCrypter.unwrapCEK(header, identity: newIdentity),
                         "new identity opens the re-keyed lid")
        XCTAssertThrowsError(try SealPackageCrypter.unwrapCEK(header, identity: identity),
                             "old identity no longer opens it")
    }

    func testStaleTempDirCannotContaminate() async throws {
        let a = try makePlainPackage(named: "a")
        // Simulate a crashed prior run's temp with a bogus extra entry.
        // Pattern matches Fix 1's .<name>.<UUID>.sealmig scheme.
        let stale = folder.appendingPathComponent(".a.seal.deadbeef.sealmig", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("evil".utf8).write(to: stale.appendingPathComponent("extra.bin"))
        _ = try await SealMigrator.encryptAll(in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        let names = try SealContainer.Reader(url: a).entries.map(\.name)
        XCTAssertFalse(names.contains("extra.bin"))
        // Stale temp cleaned up too.
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    /// One unreadable package must not abort the whole migration. The shape
    /// of "unreadable" changed with the format — a container cannot contain a
    /// stray subdirectory, so the corruption under test is a mangled archive.
    func testCorruptPackageIsSkippedNotFatal() async throws {
        let good = try makePlainPackage(named: "good")
        let bad = try makePlainPackage(named: "bad")
        try Data("not a zip at all, just bytes".utf8).write(to: bad)
        do {
            _ = try await SealMigrator.encryptAll(
                in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
            XCTFail("expected migrationIncomplete to be thrown")
        } catch {
            guard case SealMigrator.Error.migrationIncomplete(let failed, let converted) = error else {
                return XCTFail("expected migrationIncomplete, got \(error)")
            }
            XCTAssertEqual(failed.map(\.lastPathComponent), ["bad.seal"])
            XCTAssertEqual(converted, 1)
        }
        XCTAssertTrue(SealPackageCrypter.isLocked(good))
        XCTAssertFalse(SealPackageCrypter.isLocked(bad)) // untouched
    }
}

extension SealMigratorTests {
    /// Trash/restore timestamp xattrs must survive the encrypt/decrypt package
    /// rebuilds — dropping them reset every trashed item's retention clock
    /// whenever encryption was toggled.
    func test_migrationPreservesSealshotXattrs() async throws {
        let a = try makePlainPackageForXattrTest(named: "trashed", inDeleted: true)
        let stamp = "2026-07-14T02:33:02Z"
        _ = stamp.withCString { setxattr(a.path, "com.seal-shot.deletedAt", $0, strlen($0), 0, 0) }

        _ = try await SealMigrator.encryptAll(in: folder, publicKey: identity.publicKey, generation: gen) { _, _ in }
        XCTAssertEqual(readXattrForTest("com.seal-shot.deletedAt", at: a), stamp, "survives encrypt")

        _ = await SealMigrator.decryptAll(in: folder, keyFor: { _ in identity }) { _, _ in }
        XCTAssertEqual(readXattrForTest("com.seal-shot.deletedAt", at: a), stamp, "survives decrypt")
    }

    private func makePlainPackageForXattrTest(named name: String, inDeleted: Bool) throws -> URL {
        let dir = inDeleted ? folder.appendingPathComponent("Deleted") : folder!
        let url = dir.appendingPathComponent("\(name).seal", isDirectory: false)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-11T00:00:00Z", modifiedISO8601: "2026-06-11T00:00:00Z",
            sourceSize: .init(width: 4, height: 4), sourceApp: nil,
            showingEnhanced: false, metadata: nil, ocrText: "x")
        try SealContainer.write(entries: [("manifest.json", try manifest.encodeJSON())], to: url)
        return url
    }

    private func readXattrForTest(_ name: String, at url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buf, size, 0, 0) == size else { return nil }
        return String(bytes: buf, encoding: .utf8)
    }
}
