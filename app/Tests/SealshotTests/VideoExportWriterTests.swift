import XCTest
import CryptoKit
import UniformTypeIdentifiers
@testable import Sealshot

final class VideoExportWriterTests: XCTestCase {
    let identity = IdentityKey.generate()
    lazy var gen = KeyGeneration.make(publicKey: identity.publicKey)
    var encrypted: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: identity.publicKey, generation: gen, identity: identity)
    }
    var plain: SealPackageCryptoContext { SealPackageCryptoContext(publicKey: nil, identity: nil) }

    private func manifest() -> SealManifest {
        SealManifest(version: SealManifest.currentVersion, createdISO8601: "t", modifiedISO8601: "t",
                     sourceSize: .init(width: 1920, height: 1080), sourceApp: nil,
                     captureKind: .screenRecording,
                     video: VideoInfo(durationSeconds: 3.0, hasAudio: true))
    }
    private func tempPayload(_ bytes: Data) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("vw-in-\(UUID().uuidString).mov")
        try bytes.write(to: u); return u
    }
    private func pkgURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vw-rec-\(UUID().uuidString).seal")
    }
    private func destURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vw-out-\(UUID().uuidString).\(ext)")
    }
    /// A minimal ISO-BMFF head: [size=0x18][ftyp][majorBrand] + padding.
    private func ftypBytes(brand: String) -> Data {
        var d = Data([0x00, 0x00, 0x00, 0x18])
        d.append(contentsOf: "ftyp".utf8)
        d.append(contentsOf: brand.utf8)
        d.append(Data(repeating: 0, count: 12))
        return d
    }

    func testEncryptedExportRoundTrip() throws {
        let payload = Data((0..<120_000).map { UInt8(($0 * 7) & 0xff) })
        let pkg = pkgURL(); let dest = destURL("mp4")
        defer { for u in [pkg, dest] { try? FileManager.default.removeItem(at: u) } }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempPayload(payload),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: encrypted)
        try VideoExportWriter.export(packageURL: pkg, to: dest, crypto: encrypted)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testPlaintextExportRoundTrip() throws {
        let payload = ftypBytes(brand: "qt  ") + Data((0..<5_000).map { UInt8($0 & 0xff) })
        let pkg = pkgURL(); let dest = destURL("mov")
        defer { for u in [pkg, dest] { try? FileManager.default.removeItem(at: u) } }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempPayload(payload),
                                     originalUTI: "com.apple.quicktime-movie", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: plain)
        try VideoExportWriter.export(packageURL: pkg, to: dest, crypto: plain)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testCancelLeavesNoFile() throws {
        let pkg = pkgURL(); let dest = destURL("mp4")
        defer { for u in [pkg, dest] { try? FileManager.default.removeItem(at: u) } }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempPayload(Data(repeating: 9, count: 80_000)),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: encrypted)
        XCTAssertThrowsError(
            try VideoExportWriter.export(packageURL: pkg, to: dest, crypto: encrypted, isCancelled: { true })
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testLockedPackageThrows() throws {
        let pkg = pkgURL(); let dest = destURL("mp4")
        defer { for u in [pkg, dest] { try? FileManager.default.removeItem(at: u) } }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempPayload(Data([1,2,3])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: encrypted)
        XCTAssertThrowsError(try VideoExportWriter.export(packageURL: pkg, to: dest, crypto: plain)) { error in
            guard case VideoSealPackageIOError.packageLocked = error else {
                return XCTFail("expected packageLocked, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testOutputTypeEncryptedUsesOriginalUTI() throws {
        let pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempPayload(Data([1,2,3])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: encrypted)
        let resolved = VideoExportWriter.outputType(for: try VideoSealPackageIO.read(at: pkg, crypto: encrypted))
        XCTAssertEqual(resolved.ext, "mp4")
    }

    func testOutputTypePlaintextSniffsFtyp() throws {
        // quicktime brand → mov
        let movPkg = pkgURL(); defer { try? FileManager.default.removeItem(at: movPkg) }
        try VideoSealPackageIO.write(to: movPkg, payloadTempURL: try tempPayload(ftypBytes(brand: "qt  ")),
                                     originalUTI: "x", manifest: manifest(), thumbnailPNG: nil, crypto: plain)
        XCTAssertEqual(VideoExportWriter.outputType(for: try VideoSealPackageIO.read(at: movPkg, crypto: plain)).ext, "mov")
        // mp4 brand → mp4
        let mp4Pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: mp4Pkg) }
        try VideoSealPackageIO.write(to: mp4Pkg, payloadTempURL: try tempPayload(ftypBytes(brand: "mp42")),
                                     originalUTI: "x", manifest: manifest(), thumbnailPNG: nil, crypto: plain)
        XCTAssertEqual(VideoExportWriter.outputType(for: try VideoSealPackageIO.read(at: mp4Pkg, crypto: plain)).ext, "mp4")
    }

    func testPlaintextExportReportsIncrementalProgress() throws {
        // > 1 chunk (chunk size is 1 MiB) so the streaming copy reports more than once.
        let payload = Data((0..<(3 * 1_048_576 + 123)).map { UInt8($0 & 0xff) })
        let pkg = pkgURL(); let dest = destURL("mov")
        defer { for u in [pkg, dest] { try? FileManager.default.removeItem(at: u) } }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempPayload(payload),
                                     originalUTI: "com.apple.quicktime-movie", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: plain)
        var samples: [(Int, Int)] = []
        try VideoExportWriter.export(packageURL: pkg, to: dest, crypto: plain,
                                     progress: { done, total in samples.append((done, total)) })
        XCTAssertGreaterThan(samples.count, 1, "expected incremental progress, not a single end callback")
        XCTAssertEqual(samples.last?.0, payload.count)               // final done == total bytes
        XCTAssertEqual(samples.last?.1, payload.count)
        XCTAssertTrue(samples.allSatisfy { $0.1 == payload.count })  // total stable throughout
        XCTAssertEqual(try Data(contentsOf: dest), payload)          // bytes preserved
    }

    func testPlaintextCancelLeavesNoFile() throws {
        let pkg = pkgURL(); let dest = destURL("mov")
        defer { for u in [pkg, dest] { try? FileManager.default.removeItem(at: u) } }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempPayload(Data(repeating: 7, count: 80_000)),
                                     originalUTI: "com.apple.quicktime-movie", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: plain)
        XCTAssertThrowsError(
            try VideoExportWriter.export(packageURL: pkg, to: dest, crypto: plain, isCancelled: { true })
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }
}
