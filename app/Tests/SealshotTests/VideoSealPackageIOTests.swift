import XCTest
import CryptoKit
import AVFoundation
@testable import Sealshot

final class VideoSealPackageIOTests: XCTestCase {
    let identity = IdentityKey.generate()
    lazy var gen = KeyGeneration.make(publicKey: identity.publicKey)
    var encrypted: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: identity.publicKey, generation: gen, identity: identity)
    }
    var plain: SealPackageCryptoContext { SealPackageCryptoContext(publicKey: nil, identity: nil) }

    private func tempFile(_ bytes: Data) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("vid-\(UUID().uuidString).mov")
        try bytes.write(to: u); return u
    }
    private func pkgURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).seal")
    }
    private func manifest() -> SealManifest {
        SealManifest(version: SealManifest.currentVersion, createdISO8601: "t", modifiedISO8601: "t",
                     sourceSize: .init(width: 1920, height: 1080), sourceApp: nil,
                     captureKind: .screenRecording,
                     video: VideoInfo(durationSeconds: 3.0, hasAudio: true))
    }

    func testPlaintextRoundTrip() throws {
        let payload = Data((0..<50_000).map { UInt8($0 & 0xff) })
        let src = try tempFile(payload); let pkg = pkgURL()
        defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: src, originalUTI: "public.mpeg-4",
                                     manifest: manifest(), thumbnailPNG: Data([1,2,3]), crypto: plain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))  // consumed
        let c = try VideoSealPackageIO.read(at: pkg, crypto: plain)
        XCTAssertEqual(c.manifest.captureKind, .screenRecording)
        XCTAssertEqual(c.manifest.video?.durationSeconds, 3.0)
        XCTAssertNil(c.key)                                              // plaintext → no key
        XCTAssertEqual(try payloadBytes(c), payload)      // raw .mov entry
    }

    /// The payload's own bytes. Inside a container it is a byte RANGE, not a
    /// file, so reading `payloadURL` directly would hand back the whole
    /// archive — which is exactly the bug these tests should catch.
    private func payloadBytes(_ c: VideoSealContents) throws -> Data {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: temp) }
        try c.payload.stream(to: temp)
        return try Data(contentsOf: temp)
    }

    func testEncryptedRoundTrip() throws {
        let payload = Data((0..<120_000).map { UInt8(($0 * 7) & 0xff) })
        let src = try tempFile(payload); let pkg = pkgURL()
        defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: src, originalUTI: "public.mpeg-4",
                                     manifest: manifest(), thumbnailPNG: Data([1,2,3]), crypto: encrypted)
        let c = try VideoSealPackageIO.read(at: pkg, crypto: encrypted)
        XCTAssertEqual(c.manifest.video?.durationSeconds, 3.0)
        let key = try XCTUnwrap(c.key)
        // payload entry is a SealedChunkFile (NOT plaintext on disk): decrypt via Reader → bytes match.
        let onDisk = try payloadBytes(c)
        XCTAssertNotEqual(onDisk, payload, "payload must be encrypted on disk")
        // Read it in place, at the container offset — the streaming path the
        // player uses, with no extraction.
        let reader = try SealedChunkFile.Reader(url: c.payload.fileURL, key: key,
                                                baseOffset: c.payload.offset)
        XCTAssertEqual(try reader.read(offset: 0, length: payload.count), payload)
    }

    func testEncryptedReadWithWrongIdentityThrows() throws {
        let src = try tempFile(Data([9,9,9])); let pkg = pkgURL()
        defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: src, originalUTI: "public.mpeg-4",
                                     manifest: manifest(), thumbnailPNG: nil, crypto: encrypted)
        let wrong = SealPackageCryptoContext(publicKey: nil, identity: IdentityKey.generate())
        XCTAssertThrowsError(try VideoSealPackageIO.read(at: pkg, crypto: wrong))
    }

    func testOverwriteReplacesPackage() throws {
        let pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempFile(Data([1])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: plain)
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempFile(Data([2,2])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: plain)
        XCTAssertEqual(try payloadBytes(try VideoSealPackageIO.read(at: pkg, crypto: plain)),
                       Data([2,2]))
    }

    // MARK: - readThumbnailPNG

    func testReadThumbnailPNG_plaintext() throws {
        let thumbData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])  // fake PNG header bytes
        let pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempFile(Data([1,2,3])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: thumbData, crypto: plain)
        let result = try VideoSealPackageIO.readThumbnailPNG(at: pkg, crypto: plain)
        XCTAssertEqual(result, thumbData)
    }

    func testReadThumbnailPNG_encrypted() throws {
        let thumbData = Data([0x89, 0x50, 0x4E, 0x47, 0xAA, 0xBB, 0xCC, 0xDD])
        let pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempFile(Data([1,2,3])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: thumbData, crypto: encrypted)
        let result = try VideoSealPackageIO.readThumbnailPNG(at: pkg, crypto: encrypted)
        XCTAssertEqual(result, thumbData)
    }

    func testReadThumbnailPNG_missingEntryReturnsNil() throws {
        let pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: pkg) }
        // Write without a thumbnail
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempFile(Data([1,2,3])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: plain)
        let result = try VideoSealPackageIO.readThumbnailPNG(at: pkg, crypto: plain)
        XCTAssertNil(result)
    }

    func testReadThumbnailPNG_encryptedMissingEntryReturnsNil() throws {
        let pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempFile(Data([1,2,3])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: nil, crypto: encrypted)
        let result = try VideoSealPackageIO.readThumbnailPNG(at: pkg, crypto: encrypted)
        XCTAssertNil(result)
    }

    func testReadThumbnailPNG_lockedWithNoIdentityThrows() throws {
        let thumbData = Data([0x01, 0x02, 0x03])
        let pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: try tempFile(Data([1])),
                                     originalUTI: "public.mpeg-4", manifest: manifest(),
                                     thumbnailPNG: thumbData, crypto: encrypted)
        // plain context has no identity → should throw packageLocked
        XCTAssertThrowsError(try VideoSealPackageIO.readThumbnailPNG(at: pkg, crypto: plain)) { error in
            if case VideoSealPackageIOError.packageLocked = error { } else {
                XCTFail("Expected packageLocked, got \(error)")
            }
        }
    }

    // MARK: - Plaintext playback asset (extension-less payload entry)

    /// [size=0x18]["ftyp"][major brand] + padding — a minimal ISO-BMFF head.
    private func ftypBytes(brand: String) -> Data {
        var d = Data([0, 0, 0, 0x18])
        d.append(contentsOf: "ftyp".utf8)
        d.append(contentsOf: brand.utf8)
        d.append(Data(count: 12))
        return d
    }

    func testPayloadMIMEType_mapsFtypBrand() {
        XCTAssertEqual(VideoSealPackageIO.payloadMIMEType(ftypBrand: "qt  "), "video/quicktime")
        XCTAssertEqual(VideoSealPackageIO.payloadMIMEType(ftypBrand: "mp42"), "video/mp4")
        XCTAssertEqual(VideoSealPackageIO.payloadMIMEType(ftypBrand: "isom"), "video/mp4")
        // No sniffable brand → quicktime (the recorder's default container).
        XCTAssertEqual(VideoSealPackageIO.payloadMIMEType(ftypBrand: nil), "video/quicktime")
    }

    func testFtypMajorBrand_readsBrandAndRejectsNonBMFF() throws {
        let mov = try tempFile(ftypBytes(brand: "qt  "))
        defer { try? FileManager.default.removeItem(at: mov) }
        XCTAssertEqual(VideoSealPackageIO.ftypMajorBrand(at: mov), "qt  ")

        let junk = try tempFile(Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]))
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertNil(VideoSealPackageIO.ftypMajorBrand(at: junk))
    }

    /// The regression: the plaintext `payload` entry has no filename extension,
    /// so a bare `AVURLAsset(url:)` refuses it (-11828 "Cannot Open") even
    /// though the bytes are a perfectly valid movie. `plaintextPlaybackAsset()`
    /// must hint the container via the MIME override so it loads.
    func testPlaintextPlaybackAsset_loadsExtensionlessPayload() async throws {
        let mov = try TinyMovieFixture.write()
        let pkg = pkgURL(); defer { try? FileManager.default.removeItem(at: pkg) }
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: mov,
                                     originalUTI: "com.apple.quicktime-movie",
                                     manifest: manifest(), thumbnailPNG: nil, crypto: plain)
        let contents = try VideoSealPackageIO.read(at: pkg, crypto: plain)

        let built = contents.plaintextPlaybackAsset()
        let asset = built.asset
        // Retain the loader: AVFoundation holds the delegate weakly, and a
        // released one stalls loading silently instead of erroring.
        let retained = built.retain
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        _ = retained
    }
}

/// Writes a real (tiny) H.264 QuickTime movie — 4 frames of 64×64 — so AVFoundation
/// integration tests exercise an actual container, not synthetic bytes.
enum TinyMovieFixture {
    static func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<4 {
            var pb: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
                  let buffer = pb else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(40 * frame), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}
