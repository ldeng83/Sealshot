import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Sealshot

@MainActor
final class ImageImporterTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageImporterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFixturePNG(in dir: URL, named name: String,
                                 width: Int = 12, height: Int = 8) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func test_import_writesSealWithOriginalPixels_andProvenanceName() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let picture = try writeFixturePNG(in: src, named: "invoice.png", width: 12, height: 8)

        var metadataCalls: [URL] = []
        let outcome = await ImageImporter.importFiles(
            [picture], saveFolder: dst, filenameFormat: "yyyy-MM-dd",
            startMetadata: { url, _ in metadataCalls.append(url) })

        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.imported.count, 1)
        let seal = outcome.imported[0]
        XCTAssertEqual(seal.pathExtension, "seal")
        XCTAssertTrue(seal.lastPathComponent.hasPrefix("invoice "),
                      "name keeps provenance: \(seal.lastPathComponent)")
        let contents = try readSealPackage(at: seal, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.source.width, 12)
        XCTAssertEqual(contents.source.height, 8)
        XCTAssertEqual(metadataCalls, [seal], "metadata pipeline runs per import")
        // The original is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path))
    }

    func test_import_collidingNames_yieldDistinctPackages() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let a = try writeFixturePNG(in: src, named: "shot.png")
        let subdir = src.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let b = try writeFixturePNG(in: subdir, named: "shot.png")

        let outcome = await ImageImporter.importFiles(
            [a, b], saveFolder: dst, filenameFormat: "yyyy-MM-dd",
            startMetadata: { _, _ in })

        XCTAssertEqual(outcome.imported.count, 2)
        XCTAssertEqual(Set(outcome.imported.map(\.lastPathComponent)).count, 2,
                       "same-named sources must de-collide")
    }

    func test_importImage_writesSealAndNamesBySubject() throws {
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let ctx = CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 24, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!

        let first = try ImageImporter.importImage(
            image, subject: "Clipboard", saveFolder: dst, filenameFormat: "yyyy-MM-dd")
        let second = try ImageImporter.importImage(
            image, subject: "Clipboard", saveFolder: dst, filenameFormat: "yyyy-MM-dd")

        XCTAssertTrue(first.lastPathComponent.hasPrefix("Clipboard "))
        XCTAssertEqual(first.pathExtension, "seal")
        XCTAssertNotEqual(first, second, "same-second imports must de-collide")
        let contents = try readSealPackage(at: first, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.source.width, 6)
        XCTAssertEqual(contents.source.height, 4)
    }

    // MARK: PDF

    private func writeFixturePDF(in dir: URL, named name: String, pages: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 30))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func test_importPDF_eachPageBecomesACapture_namedByPage() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let pdf = try writeFixturePDF(in: src, named: "report.pdf", pages: 3)

        let outcome = await ImageImporter.importFiles(
            [pdf], saveFolder: dst, filenameFormat: "yyyy-MM-dd",
            startMetadata: { _, _ in })

        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.imported.count, 3)
        let names = outcome.imported.map(\.lastPathComponent)
        XCTAssertTrue(names[0].hasPrefix("report p1 "), "\(names)")
        XCTAssertTrue(names[2].hasPrefix("report p3 "), "\(names)")
        // Pages rasterize at 2x of the 200x100pt media box.
        let contents = try readSealPackage(at: outcome.imported[0], crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.source.width, 400)
        XCTAssertEqual(contents.source.height, 200)
    }

    func test_importPDF_singlePage_keepsPlainName() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let pdf = try writeFixturePDF(in: src, named: "receipt.pdf", pages: 1)

        let outcome = await ImageImporter.importFiles(
            [pdf], saveFolder: dst, filenameFormat: "yyyy-MM-dd",
            startMetadata: { _, _ in })

        XCTAssertEqual(outcome.imported.count, 1)
        XCTAssertTrue(outcome.imported[0].lastPathComponent.hasPrefix("receipt "),
                      "single page needs no p1 suffix: \(outcome.imported[0].lastPathComponent)")
    }

    func test_importPDF_largeDocument_promptsAndSkipsOnDecline() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let big = try writeFixturePDF(in: src, named: "book.pdf",
                                      pages: ImageImporter.largePDFPageThreshold + 1)
        let small = try writeFixturePDF(in: src, named: "memo.pdf", pages: 2)

        var prompts: [(String, Int)] = []
        let outcome = await ImageImporter.importFiles(
            [big, small], saveFolder: dst, filenameFormat: "yyyy-MM-dd",
            confirmLargeImport: { name, pages in prompts.append((name, pages)); return false },
            startMetadata: { _, _ in })

        XCTAssertEqual(prompts.count, 1, "only the large PDF prompts")
        XCTAssertEqual(prompts.first?.0, "book.pdf")
        XCTAssertEqual(prompts.first?.1, ImageImporter.largePDFPageThreshold + 1)
        XCTAssertEqual(outcome.imported.count, 2, "declined PDF skipped, memo's 2 pages land")
        XCTAssertTrue(outcome.failures.isEmpty, "a declined import is a choice, not a failure")
    }

    // MARK: plan/execute (progress + cancel)

    func test_makePlan_countsUnits_imagesOnePdfPerPage() throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let img = try writeFixturePNG(in: src, named: "a.png")
        let pdf = try writeFixturePDF(in: src, named: "doc.pdf", pages: 3)

        let plan = ImageImporter.makePlan([img, pdf])
        XCTAssertEqual(plan.totalUnits, 4)
        XCTAssertTrue(plan.failures.isEmpty)
    }

    func test_execute_reportsProgressPerUnit() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let img = try writeFixturePNG(in: src, named: "a.png")
        let pdf = try writeFixturePDF(in: src, named: "doc.pdf", pages: 2)

        var ticks: [(Int, Int)] = []
        let outcome = await ImageImporter.execute(
            ImageImporter.makePlan([img, pdf]),
            saveFolder: dst, filenameFormat: "yyyy-MM-dd",
            onUnitDone: { done, total, _ in ticks.append((done, total)) },
            startMetadata: { _, _ in })

        XCTAssertEqual(outcome.imported.count, 3)
        XCTAssertEqual(ticks.map(\.0), [1, 2, 3])
        XCTAssertEqual(ticks.map(\.1), [3, 3, 3])
    }

    func test_execute_cancelMidway_keepsLandedImports() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let pdf = try writeFixturePDF(in: src, named: "doc.pdf", pages: 5)

        var done = 0
        let outcome = await ImageImporter.execute(
            ImageImporter.makePlan([pdf]),
            saveFolder: dst, filenameFormat: "yyyy-MM-dd",
            isCancelled: { done >= 2 },
            onUnitDone: { d, _, _ in done = d },
            startMetadata: { _, _ in })

        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.imported.count, 2, "first two pages landed and stay")
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func test_import_unreadableFile_collectsFailure_othersProceed() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        let good = try writeFixturePNG(in: src, named: "good.png")
        let bad = src.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)

        let outcome = await ImageImporter.importFiles(
            [good, bad], saveFolder: dst, filenameFormat: "yyyy-MM-dd",
            startMetadata: { _, _ in })

        XCTAssertEqual(outcome.imported.count, 1)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures[0].url.lastPathComponent, "bad.png")
    }

    // MARK: - Importable format coverage

    /// Encode `image` to `dir/name` as `uti`. Returns nil if this macOS can't
    /// write that format (so the caller can skip rather than fail).
    private func writeFixture(in dir: URL, named name: String, uti: UTType,
                             width: Int = 16, height: Int = 12) -> URL? {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, uti.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    /// Every format we advertise in the import panel must actually be decodable
    /// by the ImageIO path `decode(_:)` uses — directly, or as an umbrella that
    /// some concrete decodable type conforms to (e.g. camera RAW). PDF decodes
    /// via PDFKit and movies via AVFoundation, so they're exempt.
    func test_importableContentTypes_areDecodableByImageIO() {
        let decodable = (CGImageSourceCopyTypeIdentifiers() as! [String]).compactMap { UTType($0) }
        let nonImageIO: Set<UTType> = [.pdf, .movie, .quickTimeMovie, .mpeg4Movie]
        for type in ImageImporter.importableContentTypes where !nonImageIO.contains(type) {
            let ok = decodable.contains { $0 == type || $0.conforms(to: type) }
            XCTAssertTrue(ok, "advertised import type \(type.identifier) is not ImageIO-decodable")
        }
    }

    func test_isImportable_acceptsSupportedExtensions_rejectsOthers() {
        let yes = ["png", "apng", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif",
                   "bmp", "webp", "avif", "ico", "pdf", "dng", "cr3", "nef", "arw",
                   "PNG", "WebP", "AVIF"]
        for ext in yes {
            XCTAssertTrue(ImageImporter.isImportable(URL(fileURLWithPath: "/x/file.\(ext)")),
                          ".\(ext) should be importable")
        }
        for ext in ["txt", "svg", "eps", "key", "zip", ""] {
            XCTAssertFalse(ImageImporter.isImportable(URL(fileURLWithPath: "/x/file.\(ext)")),
                           ".\(ext) should not be importable")
        }
    }

    func test_importableContentTypes_includeNewlyAddedFormats() {
        let ids = Set(ImageImporter.importableContentTypes.map(\.identifier))
        for expected in [UTType.webP.identifier, UTType.heif.identifier,
                         UTType.ico.identifier, UTType.rawImage.identifier, "public.avif"] {
            XCTAssertTrue(ids.contains(expected), "import panel should offer \(expected)")
        }
    }

    func test_import_ico_decodesThroughPipeline() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        guard let pic = writeFixture(in: src, named: "favicon.ico", uti: .ico,
                                     width: 16, height: 16) else {
            throw XCTSkip("this macOS can't encode ICO")
        }
        let outcome = await ImageImporter.importFiles(
            [pic], saveFolder: dst, filenameFormat: "yyyy-MM-dd", startMetadata: { _, _ in })
        XCTAssertTrue(outcome.failures.isEmpty, "ICO should import: \(outcome.failures)")
        XCTAssertEqual(outcome.imported.count, 1)
    }

    func test_import_avif_decodesThroughPipeline() async throws {
        let src = tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let dst = tempDir(); defer { try? FileManager.default.removeItem(at: dst) }
        guard let avif = UTType("public.avif"),
              let pic = writeFixture(in: src, named: "photo.avif", uti: avif,
                                     width: 16, height: 12) else {
            throw XCTSkip("this macOS can't encode AVIF")
        }
        let outcome = await ImageImporter.importFiles(
            [pic], saveFolder: dst, filenameFormat: "yyyy-MM-dd", startMetadata: { _, _ in })
        XCTAssertTrue(outcome.failures.isEmpty, "AVIF should import: \(outcome.failures)")
        XCTAssertEqual(outcome.imported.count, 1)
        let contents = try readSealPackage(
            at: outcome.imported[0], crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.source.width, 16)
        XCTAssertEqual(contents.source.height, 12)
    }
}
