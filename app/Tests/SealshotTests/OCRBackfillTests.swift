import XCTest
import CoreGraphics
@testable import Sealshot

/// Background backfill: OCR old .seal packages (manifest `ocrText == nil`)
/// and patch the text in, without ever touching title/tags.
@MainActor
final class OCRBackfillTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func img() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @discardableResult
    private func makeSeal(_ name: String, in dir: URL? = nil, ocrText: String? = nil) throws -> URL {
        let url = (dir ?? folder).appendingPathComponent("\(name).seal")
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        if let ocrText { try SealMetadataStore.applyOCRText(ocrText, to: url) }
        return url
    }

    func testRun_patchesOnlyPackagesWithoutOCRText() async throws {
        let old = try makeSeal("old")                       // ocrText == nil → backfill
        let done = try makeSeal("done", ocrText: "already") // skipped
        var ocrCalls = 0
        let coordinator = OCRBackfillCoordinator(ocr: { _ in ocrCalls += 1; return "found text" })

        await coordinator.run(saveFolder: folder)

        XCTAssertEqual(ocrCalls, 1)
        XCTAssertEqual(try SealMetadataStore.readManifest(at: old).ocrText, "found text")
        XCTAssertEqual(try SealMetadataStore.readManifest(at: done).ocrText, "already")
    }

    func testRun_includesDeletedSubfolder() async throws {
        let trash = folder.appendingPathComponent(SealDeleter.deletedSubfolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = try makeSeal("trashed", in: trash)
        let coordinator = OCRBackfillCoordinator(ocr: { _ in "trash text" })

        await coordinator.run(saveFolder: folder)

        XCTAssertEqual(try SealMetadataStore.readManifest(at: trashed).ocrText, "trash text")
    }

    func testRun_ocrFailure_skipsAndContinues() async throws {
        struct Boom: Error {}
        try makeSeal("a")
        try makeSeal("b")
        var calls = 0
        let coordinator = OCRBackfillCoordinator(ocr: { _ in
            calls += 1
            if calls == 1 { throw Boom() }
            return "second ok"
        })

        await coordinator.run(saveFolder: folder)

        XCTAssertEqual(calls, 2, "a failure must not stop the queue")
        // Exactly one of the two got patched (order-independent).
        let texts = try [folder.appendingPathComponent("a.seal"),
                         folder.appendingPathComponent("b.seal")]
            .map { try SealMetadataStore.readManifest(at: $0).ocrText }
        XCTAssertEqual(texts.compactMap { $0 }, ["second ok"])
    }

    func testRun_neverTouchesMetadata() async throws {
        let url = try makeSeal("meta")
        let meta = CaptureMetadata(generatedTitle: "Keep", userTitle: "Mine", tags: ["x"],
                                   category: .code, confidence: 0.9, generatorVersion: 1)
        try SealMetadataStore.apply(metadata: meta, sourceApp: "Xcode", to: url)
        let coordinator = OCRBackfillCoordinator(ocr: { _ in "text" })

        await coordinator.run(saveFolder: folder)

        let m = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(m.metadata, meta)
        XCTAssertEqual(m.ocrText, "text")
    }

    func testRun_cancelledTask_doesNoWork() async throws {
        try makeSeal("a")
        var calls = 0
        let coordinator = OCRBackfillCoordinator(ocr: { _ in calls += 1; return "x" })

        let task = Task { await coordinator.run(saveFolder: folder) }
        task.cancel()   // cancellation is sticky — run() sees it at the first check
        await task.value

        XCTAssertEqual(calls, 0)
        XCTAssertNil(try SealMetadataStore.readManifest(at: folder.appendingPathComponent("a.seal")).ocrText)
    }

    /// The capture pipeline claims a package before enqueueing its OCR, and the
    /// package sits on disk with `ocrText == nil` the whole time that OCR runs —
    /// so without the claim, backfill would recognize the same image in parallel.
    func testRun_skipsPackagesClaimedByTheMetadataPipeline() async throws {
        let claimed = try makeSeal("claimed")
        let free = try makeSeal("free")
        OCRInFlightRegistry.shared.add(claimed)
        defer { OCRInFlightRegistry.shared.remove(claimed) }
        var ocrCalls = 0
        let coordinator = OCRBackfillCoordinator(ocr: { _ in ocrCalls += 1; return "backfilled" })

        await coordinator.run(saveFolder: folder)

        XCTAssertEqual(ocrCalls, 1, "only the unclaimed package may be OCR'd")
        XCTAssertNil(try SealMetadataStore.readManifest(at: claimed).ocrText)
        XCTAssertEqual(try SealMetadataStore.readManifest(at: free).ocrText, "backfilled")
    }

    /// The pending list is a snapshot; a capture whose own OCR lands between the
    /// listing and its turn in the loop must not be recognized again.
    func testRun_skipsPackagesOCRdAfterTheListingSnapshot() async throws {
        let first = try makeSeal("a-first")
        let second = try makeSeal("b-second")
        // Simulate the capture pipeline finishing `second`'s OCR while the loop
        // is busy with `first`.
        let coordinator = OCRBackfillCoordinator(ocr: { _ in
            try? SealMetadataStore.applyOCRText("written by capture", to: second)
            return "backfilled"
        })

        await coordinator.run(saveFolder: folder)

        XCTAssertEqual(try SealMetadataStore.readManifest(at: first).ocrText, "backfilled")
        XCTAssertEqual(try SealMetadataStore.readManifest(at: second).ocrText, "written by capture",
                       "backfill must not overwrite text the capture pipeline just wrote")
    }

    func testRun_isIdempotentAcrossLaunches() async throws {
        try makeSeal("a")
        var calls = 0
        let coordinator = OCRBackfillCoordinator(ocr: { _ in calls += 1; return "t" })
        await coordinator.run(saveFolder: folder)
        await coordinator.run(saveFolder: folder)   // second "launch"
        XCTAssertEqual(calls, 1)
    }
}
