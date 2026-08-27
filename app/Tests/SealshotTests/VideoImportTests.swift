import XCTest
import AVFoundation
@testable import Sealshot

/// Direct video import (⌘O / drop-to-import): movie files become unified
/// video .seal packages, like recordings and .sealshare video imports.
@MainActor
final class VideoImportTests: XCTestCase {

    func test_plan_classifiesMoviesAsVideoItems() {
        let plan = ImageImporter.makePlan([
            URL(fileURLWithPath: "/tmp/clip.mov"),
            URL(fileURLWithPath: "/tmp/clip.MP4"),
            URL(fileURLWithPath: "/tmp/pic.png"),
        ])
        XCTAssertEqual(plan.items.count, 3)
        guard case .video = plan.items[0] else { return XCTFail("mov → .video") }
        guard case .video = plan.items[1] else { return XCTFail("MP4 → .video (case-insensitive)") }
        guard case .image = plan.items[2] else { return XCTFail("png stays .image") }
    }

    func test_isImportable_acceptsMovies() {
        XCTAssertTrue(ImageImporter.isImportable(URL(fileURLWithPath: "/t/a.mov")))
        XCTAssertTrue(ImageImporter.isImportable(URL(fileURLWithPath: "/t/a.m4v")))
        XCTAssertFalse(ImageImporter.isImportable(URL(fileURLWithPath: "/t/a.avi")))
    }

    func test_importVideo_writesUnifiedVideoSeal_keepsSource() async throws {
        let movie = try TinyMovieFixture.write()
        defer { try? FileManager.default.removeItem(at: movie) }
        let save = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidimport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: save) }

        let dest = try await ImageImporter.importVideo(
            movie, subject: "Clip", saveFolder: save,
            filenameFormat: CaptureConfig().filenameFormat, now: Date())

        XCTAssertEqual(dest.pathExtension, "seal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path),
                      "the user's source file is never consumed")
        let contents = try VideoSealPackageIO.read(
            at: dest, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.manifest.captureKind, .importedVideo)
        XCTAssertEqual(contents.manifest.sourceSize.width, 64)
        XCTAssertGreaterThan(contents.manifest.video?.durationSeconds ?? 0, 0)
        // Plaintext payload plays back byte-for-byte.
        // The payload is a byte RANGE inside the container — reading
        // `payloadURL` directly would compare the whole archive.
        let extracted = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-payload-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: extracted) }
        try contents.payload.stream(to: extracted)
        XCTAssertEqual(try Data(contentsOf: extracted), try Data(contentsOf: movie))
    }

    func test_importVideo_undecodableJunk_throws() async throws {
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("junk-\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let save = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidjunk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: save) }
        do {
            _ = try await ImageImporter.importVideo(
                junk, subject: "J", saveFolder: save,
                filenameFormat: CaptureConfig().filenameFormat, now: Date())
            XCTFail("expected undecodable throw")
        } catch {}
    }
}
