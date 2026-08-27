import XCTest
import CryptoKit
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers
@testable import Sealshot

final class SharePackageImporterTests: XCTestCase {
    private var dir: URL!
    private let format = "yyyy-MM-dd-HH-mm-ss"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func pngData() -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Build a .sealshare directly via the core write API. `videoPayload` non-nil adds a video entry.
    private func makePackage(image: Bool, videoPayload: Data?, passphrase: String = "open sesame") throws -> URL {
        var entries: [SealSharePackage.EntryInput] = []
        if image {
            entries.append(.init(name: "shot.png", kind: .image, uti: "public.png",
                                 title: nil, tags: [], imageData: pngData(), videoURL: nil))
        }
        if let payload = videoPayload {
            let mov = dir.appendingPathComponent("clip.mov")
            try payload.write(to: mov)
            entries.append(.init(name: "clip", kind: .video, uti: "com.apple.quicktime-movie",
                                 title: nil, tags: [], imageData: nil, videoURL: mov))
        }
        let pkg = dir.appendingPathComponent("pkg.sealshare")
        try SealSharePackage.write(entries: entries,
            options: .init(recipients: [.passphrase(passphrase, hint: nil)],
                           expiresAt: nil, note: nil, includesOriginal: false), to: pkg)
        return pkg
    }

    private func unlock(_ pkg: URL) throws -> SealSharePackage.Unlocked {
        try SealSharePackage.Reader(url: pkg).unlock(passphrase: "open sesame")
    }

    private var plainCrypto: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: nil, generation: nil, identity: nil)
    }

    func testImportToFolderWritesPlaintext() async throws {
        let payload = Data("movie-bytes-123456".utf8)
        let unlocked = try unlock(try makePackage(image: true, videoPayload: payload))
        let out = dir.appendingPathComponent("extracted", isDirectory: true)
        let summary = try await SharePackageImporter.importToFolder(unlocked, destinationFolder: out) { _, _ in }
        XCTAssertEqual(summary.imported, 2)
        XCTAssertTrue(summary.failed.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(files.count, 2)
        // image decodes; video bytes match
        let imageFile = files.first { $0.hasSuffix(".png") }!
        XCTAssertNotNil(NSImage(contentsOf: out.appendingPathComponent(imageFile)))
        let videoFile = files.first { !$0.hasSuffix(".png") }!
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(videoFile)), payload)
    }

    func testImportToLibraryPlaintext() async throws {
        let payload = Data("plain-movie".utf8)
        let unlocked = try unlock(try makePackage(image: true, videoPayload: payload))
        let save = dir.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        let summary = try await SharePackageImporter.importToLibrary(
            unlocked, saveFolder: save, filenameFormat: format, crypto: plainCrypto,
            now: now) { _, _ in }
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.importedURLs.count, 2, "library imports report URLs for the Import ⌘Z event")
        // BOTH entries land as .seal packages in saveFolder — the video as a
        // unified video .seal (no more legacy .sealrec / bare .mov deposits,
        // which nothing in the app can play).
        let seals = try FileManager.default.contentsOfDirectory(atPath: save.path).filter { $0.hasSuffix(".seal") }
        XCTAssertEqual(seals.count, 2)
        var sawImage = false, sawVideo = false
        for name in seals {
            let url = save.appendingPathComponent(name)
            if let contents = try? VideoSealPackageIO.read(at: url, crypto: plainCrypto),
               contents.manifest.captureKind == .importedVideo {
                sawVideo = true
                XCTAssertNil(contents.key, "plaintext crypto → plaintext payload")
                // A byte range inside the container, not a file of its own.
                let out = dir.appendingPathComponent("payload-\(UUID().uuidString).bin")
                try contents.payload.stream(to: out)
                XCTAssertEqual(try Data(contentsOf: out), payload)
            } else {
                sawImage = true
                let contents = try await readSealPackage(at: url, crypto: plainCrypto)
                XCTAssertGreaterThan(contents.composite.width, 0)
            }
        }
        XCTAssertTrue(sawImage); XCTAssertTrue(sawVideo)
    }

    func testImportToLibraryEncryptedVideoRoundTrips() async throws {
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let crypto = SealPackageCryptoContext(publicKey: id.publicKey, generation: gen, identity: id)
        let payload = Data("encrypted-movie-bytes".utf8)
        let unlocked = try unlock(try makePackage(image: false, videoPayload: payload))
        let save = dir.appendingPathComponent("save2", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        let summary = try await SharePackageImporter.importToLibrary(
            unlocked, saveFolder: save, filenameFormat: format, crypto: crypto,
            now: now) { _, _ in }
        XCTAssertEqual(summary.imported, 1)
        // Encrypted video .seal in the save folder, sealed with the PACKAGE
        // crypto (no separate recordings key needed anymore).
        let seals = try FileManager.default.contentsOfDirectory(atPath: save.path).filter { $0.hasSuffix(".seal") }
        XCTAssertEqual(seals.count, 1)
        let contents = try VideoSealPackageIO.read(at: save.appendingPathComponent(seals[0]), crypto: crypto)
        XCTAssertEqual(contents.manifest.captureKind, .importedVideo)
        let cek = try XCTUnwrap(contents.key)
        let decoded = dir.appendingPathComponent("decoded.mov")
        try SealedChunkFile.decryptWhole(contents.payload.fileURL, to: decoded, key: cek,
                                         baseOffset: contents.payload.offset)
        XCTAssertEqual(try Data(contentsOf: decoded), payload)
    }

    func testImportToFolderForcesImageExtension() async throws {
        // Build a package with an image entry whose name has an embedded dot.
        let pkg = dir.appendingPathComponent("dotpkg.sealshare")
        try SealSharePackage.write(entries: [
            .init(name: "report.v2", kind: .image, uti: "public.png",
                  title: nil, tags: [], imageData: pngData(), videoURL: nil)
        ], options: .init(recipients: [.passphrase("open sesame", hint: nil)],
                          expiresAt: nil, note: nil, includesOriginal: false), to: pkg)
        let unlocked = try SealSharePackage.Reader(url: pkg).unlock(passphrase: "open sesame")
        let out = dir.appendingPathComponent("dotout", isDirectory: true)
        _ = try await SharePackageImporter.importToFolder(unlocked, destinationFolder: out) { _, _ in }
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".png"), "got \(files[0])")
    }

    func testImportPlaintextToFolderWritesRawFiles() async throws {
        // Build a plaintext package (no recipients → no encryption) with one image entry.
        let imgData = pngData()
        let pkg = dir.appendingPathComponent("plain.sealshare")
        try SealSharePackage.write(
            entries: [.init(name: "shot.png", kind: .image, uti: "public.png",
                            title: nil, tags: [], imageData: imgData, videoURL: nil)],
            options: .init(recipients: [], expiresAt: nil, note: nil, includesOriginal: false),
            to: pkg)
        // Unlock via the plaintext path (no passphrase).
        let unlocked = try SealSharePackage.Reader(url: pkg).unlockPlaintext()
        // Import to folder and verify the raw image file is present with the original bytes.
        let out = dir.appendingPathComponent("plain-out", isDirectory: true)
        let summary = try await SharePackageImporter.importToFolder(unlocked, destinationFolder: out) { _, _ in }
        XCTAssertEqual(summary.imported, 1)
        XCTAssertTrue(summary.failed.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(files.count, 1)
        let imageFile = try XCTUnwrap(files.first { $0.hasSuffix(".png") })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(imageFile)), imgData)
    }

    func testImportToLibrary_stampsCollectionMembership() async throws {
        let unlocked = try unlock(try makePackage(image: true, videoPayload: nil))
        let save = dir.appendingPathComponent("save-coll", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        let collectionID = UUID()
        let summary = try await SharePackageImporter.importToLibrary(
            unlocked, saveFolder: save, filenameFormat: format, crypto: plainCrypto,
            now: now, collectionID: collectionID) { _, _ in }
        XCTAssertEqual(summary.imported, 1)
        let seals = try FileManager.default.contentsOfDirectory(atPath: save.path)
            .filter { $0.hasSuffix(".seal") }
        let sealURL = save.appendingPathComponent(seals[0])
        // Read the manifest back and assert membership was stamped.
        let ids = try await SealMetadataStore.collections(of: sealURL)
        XCTAssertEqual(ids, [collectionID])
    }

    /// The old importer needed a separate recordings key for encrypted video
    /// deposits and HARD-FAILED without one. Unified video .seal packages are
    /// sealed with the package crypto, so the same import now succeeds.
    func testEncryptedVideoImport_succeedsWithoutRecordingsKey() async throws {
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let crypto = SealPackageCryptoContext(publicKey: id.publicKey, generation: gen, identity: id)
        let unlocked = try unlock(try makePackage(image: false, videoPayload: Data("v".utf8)))
        let save = dir.appendingPathComponent("save3", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        let summary = try await SharePackageImporter.importToLibrary(
            unlocked, saveFolder: save, filenameFormat: format, crypto: crypto,
            now: now) { _, _ in }
        XCTAssertEqual(summary.imported, 1)
        XCTAssertTrue(summary.failed.isEmpty)
    }
}
