import XCTest
import CryptoKit
import CoreGraphics
import AppKit
@testable import Sealshot

final class SharePackageBuilderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var plainCrypto: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: nil, generation: nil, identity: nil)
    }

    private func makeCGImage(_ w: Int = 4, _ h: Int = 4) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Build a .seal on disk. Plaintext when crypto has no key; locked when it has publicKey+generation.
    private func makeSeal(named name: String, crypto: SealPackageCryptoContext) throws -> URL {
        let url = dir.appendingPathComponent("\(name).seal", isDirectory: true)
        let img = makeCGImage()
        try writeSealPackage(to: url, source: img, composite: img, annotations: [], crop: nil, crypto: crypto)
        return url
    }

    private func dest(_ name: String = "out") -> URL {
        dir.appendingPathComponent("\(name).sealshare")
    }

    func testEmptySourcesThrows() async {
        let req = SharePackageRequest(sources: [], encryption: .passphrase("open sesame", hint: nil), note: nil,
                                      expiresAt: nil, includeOriginal: false, destination: dest())
        do { try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)
             XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? SharePackageBuildError, .nothingToExport) }
    }

    func testPlaintextImageRoundTrip() async throws {
        let seal = try makeSeal(named: "shot", crypto: plainCrypto)
        let out = dest()
        let req = SharePackageRequest(sources: [.init(url: seal, displayName: "shot", isVideo: false)],
                                      encryption: .passphrase("open sesame", hint: nil), note: "n", expiresAt: nil,
                                      includeOriginal: false, destination: out)
        try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)

        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")
        XCTAssertEqual(unlocked.manifest.entries.count, 1)
        XCTAssertEqual(unlocked.manifest.note, "n")
        XCTAssertFalse(unlocked.manifest.includesOriginal)
        XCTAssertNotNil(NSImage(data: try unlocked.imageData(forEntry: "shot.png")))
    }

    /// The sidecar describes the UN-redacted source; a shared package carries
    /// the redacted composite. Shipping the two together would hand the
    /// recipient the text that redaction was applied to remove.
    ///
    /// True by construction today — the builder re-renders `composite`/`source`
    /// rather than copying package entries — which is exactly why it needs a
    /// test. Nothing would stop a later change from copying entries wholesale.
    func testDerivedSidecarNeverReachesASharePackage() async throws {
        let seal = try makeSeal(named: "shot", crypto: plainCrypto)
        var sidecar = DerivedSidecar()
        let secret = "TOPSECRETREDACTEDTEXT"
        sidecar.setSection(TextLayoutSection.name, data: Data(secret.utf8))
        try writeDerivedSidecar(sidecar, into: seal, crypto: plainCrypto)

        let out = dest()
        let req = SharePackageRequest(sources: [.init(url: seal, displayName: "shot", isVideo: false)],
                                      encryption: .passphrase("open sesame", hint: nil), note: nil,
                                      expiresAt: nil, includeOriginal: false, destination: out)
        try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)

        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")
        XCTAssertEqual(unlocked.manifest.entries.count, 1, "only the rendered image should ship")
        XCTAssertFalse(unlocked.manifest.entries.contains { $0.name.contains("derived") })

        // Belt and braces: the text must not survive anywhere in the bytes.
        let bytes = try Data(contentsOf: out)
        XCTAssertNil(bytes.range(of: Data(secret.utf8)),
                     "derived text reached the shared package")
    }

    func testBuild_onItemFiresOncePerSource() async throws {
        let a = try makeSeal(named: "a", crypto: plainCrypto)
        let b = try makeSeal(named: "b", crypto: plainCrypto)
        let c = try makeSeal(named: "c", crypto: plainCrypto)
        let req = SharePackageRequest(
            sources: [.init(url: a, displayName: "a", isVideo: false),
                      .init(url: b, displayName: "b", isVideo: false),
                      .init(url: c, displayName: "c", isVideo: false)],
            encryption: .none, note: nil, expiresAt: nil,
            includeOriginal: true, destination: dest())   // includeOriginal doubles ENTRIES, not items

        let items = ProgressCounter()
        try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil,
                                            onBytes: nil, onItem: { items.add(1) })
        // One tick per SOURCE (3), not per entry (would be 6 with originals).
        XCTAssertEqual(items.current, 3)
    }

    func testIncludeOriginalAddsSecondEntry() async throws {
        let seal = try makeSeal(named: "shot", crypto: plainCrypto)
        let out = dest()
        let req = SharePackageRequest(sources: [.init(url: seal, displayName: "shot", isVideo: false)],
                                      encryption: .passphrase("open sesame", hint: nil), note: nil, expiresAt: nil,
                                      includeOriginal: true, destination: out)
        try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)

        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")
        XCTAssertEqual(unlocked.manifest.entries.count, 2)
        XCTAssertTrue(unlocked.manifest.includesOriginal)
        XCTAssertNotNil(NSImage(data: try unlocked.imageData(forEntry: "shot.png")))
        XCTAssertNotNil(NSImage(data: try unlocked.imageData(forEntry: "shot-original.png")))
    }

    func testLockedImageRoundTrip() async throws {
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let crypto = SealPackageCryptoContext(publicKey: id.publicKey, generation: gen, identity: id)
        let seal = try makeSeal(named: "locked", crypto: crypto)
        let out = dest()
        let req = SharePackageRequest(sources: [.init(url: seal, displayName: "locked", isVideo: false)],
                                      encryption: .passphrase("open sesame", hint: nil), note: nil, expiresAt: nil,
                                      includeOriginal: false, destination: out)
        try await SharePackageBuilder.build(req, crypto: crypto, recordingsKey: nil, onBytes: nil)
        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")
        XCTAssertNotNil(NSImage(data: try unlocked.imageData(forEntry: "locked.png")))
    }

    func testLockedSourceWithoutIdentityThrows() async throws {
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let lockedCrypto = SealPackageCryptoContext(publicKey: id.publicKey, generation: gen, identity: id)
        let seal = try makeSeal(named: "locked", crypto: lockedCrypto)
        let noIdentity = SealPackageCryptoContext(publicKey: id.publicKey, generation: gen, identity: nil)
        let req = SharePackageRequest(sources: [.init(url: seal, displayName: "locked", isVideo: false)],
                                      encryption: .passphrase("open sesame", hint: nil), note: nil, expiresAt: nil,
                                      includeOriginal: false, destination: dest())
        do { try await SharePackageBuilder.build(req, crypto: noIdentity, recordingsKey: nil, onBytes: nil)
             XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? SharePackageBuildError, .sourceLocked(seal)) }
    }

    /// A recording stored as a `.seal` package (encrypted payload) must export
    /// through the builder — regression for "Is a directory" (POSIX 21) when the
    /// `.seal` directory was read as a raw movie file.
    func testVideoSealPackageRoundTrip() async throws {
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let crypto = SealPackageCryptoContext(publicKey: id.publicKey, generation: gen, identity: id)
        // Build an encrypted video `.seal` whose payload is known bytes.
        let payload = Data((0..<50_000).map { UInt8(($0 * 13) & 0xff) })
        let payloadTemp = dir.appendingPathComponent("in.mov")
        try payload.write(to: payloadTemp)
        let videoSeal = dir.appendingPathComponent("rec.seal", isDirectory: true)
        let manifest = SealManifest(version: SealManifest.currentVersion, createdISO8601: "t",
                                    modifiedISO8601: "t", sourceSize: .init(width: 1920, height: 1080),
                                    sourceApp: nil, captureKind: .screenRecording,
                                    video: VideoInfo(durationSeconds: 3.0, hasAudio: true))
        try VideoSealPackageIO.write(to: videoSeal, payloadTempURL: payloadTemp,
                                     originalUTI: "public.mpeg-4", manifest: manifest,
                                     thumbnailPNG: nil, crypto: crypto)

        // Export it as a (plaintext) share package.
        let out = dest()
        let req = SharePackageRequest(sources: [.init(url: videoSeal, displayName: "rec", isVideo: true)],
                                      encryption: .none, note: nil, expiresAt: nil,
                                      includeOriginal: false, destination: out)
        try await SharePackageBuilder.build(req, crypto: crypto, recordingsKey: nil, onBytes: nil)

        // The extracted video must equal the original payload.
        let unlocked = try SealSharePackage.Reader(url: out).unlockPlaintext()
        let recovered = dir.appendingPathComponent("recovered.mov")
        try unlocked.extractVideo(forEntry: "rec", to: recovered)
        XCTAssertEqual(try Data(contentsOf: recovered), payload)
    }

    func testEncryptedVideoRoundTrip() async throws {
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("clip.mov")
        let payload = Data("movie-bytes-0123456789".utf8)
        try payload.write(to: plain)
        let sealrec = dir.appendingPathComponent("clip.sealrec")
        try SealedChunkFile.encrypt(plaintextURL: plain, to: sealrec, key: key, originalUTI: "public.mpeg-4")

        let out = dest()
        let req = SharePackageRequest(sources: [.init(url: sealrec, displayName: "clip", isVideo: true)],
                                      encryption: .passphrase("open sesame", hint: nil), note: nil, expiresAt: nil,
                                      includeOriginal: false, destination: out)
        try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: key, onBytes: nil)

        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")
        let recovered = dir.appendingPathComponent("recovered.mov")
        try unlocked.extractVideo(forEntry: "clip", to: recovered)
        XCTAssertEqual(try Data(contentsOf: recovered), payload)
    }

    func testEncryptedVideoWithoutKeyThrows() async throws {
        let key = SymmetricKey(size: .bits256)
        let plain = dir.appendingPathComponent("clip.mov")
        try Data("x".utf8).write(to: plain)
        let sealrec = dir.appendingPathComponent("clip.sealrec")
        try SealedChunkFile.encrypt(plaintextURL: plain, to: sealrec, key: key, originalUTI: "public.mpeg-4")
        let req = SharePackageRequest(sources: [.init(url: sealrec, displayName: "clip", isVideo: true)],
                                      encryption: .passphrase("open sesame", hint: nil), note: nil, expiresAt: nil,
                                      includeOriginal: false, destination: dest())
        do { try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)
             XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? SharePackageBuildError, .recordingsKeyUnavailable(sealrec)) }
    }

    func testPlaintextVideoRoundTrip() async throws {
        let plain = dir.appendingPathComponent("clip.mov")
        let payload = Data("plain-movie-bytes".utf8)
        try payload.write(to: plain)
        let out = dest()
        let req = SharePackageRequest(sources: [.init(url: plain, displayName: "clip", isVideo: true)],
                                      encryption: .passphrase("open sesame", hint: nil), note: nil, expiresAt: nil,
                                      includeOriginal: false, destination: out)
        try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)
        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")
        let recovered = dir.appendingPathComponent("recovered.mov")
        try unlocked.extractVideo(forEntry: "clip", to: recovered)
        XCTAssertEqual(try Data(contentsOf: recovered), payload)
    }

    func testPrepareZipEntriesImageAndOriginal() async throws {
        let seal = try makeSeal(named: "shot", crypto: plainCrypto)
        let src = SharePackageSource(url: seal, displayName: "shot", isVideo: false)
        let entries = try await SharePackageBuilder.prepareZipEntries(
            [src], includeOriginal: true, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.name == "shot.png" })
        XCTAssertTrue(entries.contains { $0.name == "shot-original.png" })
        XCTAssertEqual(Array(entries[0].data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic
    }

    func testPrepareZipEntriesDedupesAndSanitizes() async throws {
        let sealA = try makeSeal(named: "a", crypto: plainCrypto)
        let sealB = try makeSeal(named: "b", crypto: plainCrypto)
        let a = SharePackageSource(url: sealA, displayName: "../evil", isVideo: false)
        let b = SharePackageSource(url: sealB, displayName: "../evil", isVideo: false)
        let entries = try await SharePackageBuilder.prepareZipEntries(
            [a, b], includeOriginal: false, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)
        XCTAssertEqual(entries.count, 2)
        for e in entries {
            XCTAssertFalse(e.name.contains(".."))
            XCTAssertFalse(e.name.contains("/"))
        }
        XCTAssertNotEqual(entries[0].name, entries[1].name) // deduped
    }

    func testBuildPlaintextProducesUnencryptedPackage() async throws {
        let seal = try makeSeal(named: "shot", crypto: plainCrypto)
        let out = dest("plaintext-out")
        let req = SharePackageRequest(sources: [.init(url: seal, displayName: "shot", isVideo: false)],
                                      encryption: .none, note: nil, expiresAt: nil,
                                      includeOriginal: false, destination: out)
        try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)

        let reader = try SealSharePackage.Reader(url: out)
        XCTAssertFalse(reader.isEncrypted)
        let unlocked = try reader.unlockPlaintext()
        XCTAssertFalse(try unlocked.imageData(forEntry: "shot.png").isEmpty)
    }

    func testPrepareZipEntriesCancelThrows() async throws {
        let seal = try makeSeal(named: "a", crypto: plainCrypto)
        let src = SharePackageSource(url: seal, displayName: "a", isVideo: false)
        let task = Task {
            try await SharePackageBuilder.prepareZipEntries(
                [src], includeOriginal: false, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testBuild_populatesManifestCollection() async throws {
        let seal = try makeSeal(named: "shot", crypto: plainCrypto)
        let out = dest()
        let desc = ShareCollectionDescriptor(id: UUID(), name: "Album")
        let req = SharePackageRequest(
            sources: [.init(url: seal, displayName: "shot", isVideo: false)],
            encryption: .none, note: nil, expiresAt: nil,
            includeOriginal: false, destination: out, collection: desc)
        try await SharePackageBuilder.build(req, crypto: plainCrypto, recordingsKey: nil, onBytes: nil)
        let manifest = try SealSharePackage.Reader(url: out).unlockPlaintext().manifest
        XCTAssertEqual(manifest.collection, desc)
    }
}
