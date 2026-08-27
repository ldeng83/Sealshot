import XCTest
import CoreGraphics
@testable import Sealshot

/// The cache hands back text geometry computed from a specific set of pixels.
/// A key that is too loose returns boxes that no longer line up with the image
/// — selection highlights land on the wrong words — so these tests pin the
/// cases that MUST NOT share an entry.
///
/// The fixtures build real `.seal` packages now. The key is anchored on the
/// manifest's stamp rather than the file's mtime (the layout is written INTO
/// the package, and that write moves the mtime), so there has to be a manifest
/// to read.
@MainActor
final class TextLayoutCacheTests: XCTestCase {

    private var url: URL!
    private var plain: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: nil, identity: nil)
    }

    private func image(_ w: Int = 8, _ h: Int = 8, red: Double = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @discardableResult
    private func writePackage(at u: URL, red: Double = 0) throws -> URL {
        let img = image(red: red)
        _ = try writeSealPackage(to: u, source: img, composite: img, annotations: [],
                                 crop: nil, crypto: plain)
        return u
    }

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-\(UUID().uuidString).seal")
        try writePackage(at: url)
        TextLayoutCache.shared.removeAll()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
        TextLayoutCache.shared.removeAll()
    }

    private func key(enhanced: Bool = false, cutout: Bool = false,
                     size: CGSize = CGSize(width: 100, height: 50),
                     crop: CGRect? = nil, at u: URL? = nil) throws -> TextLayoutKey {
        try XCTUnwrap(TextLayoutCache.key(sourceURL: u ?? url, baseSize: size,
                                          showingEnhanced: enhanced, showingCutout: cutout,
                                          croppedRect: crop))
    }

    private func layout(_ text: String) -> RecognizedTextLayout {
        RecognizedTextLayout(lines: [
            RecognizedLine(text: text, box: CGRect(x: 0, y: 0, width: 1, height: 0.1),
                           charBoxes: [], quad: nil)
        ])
    }

    func test_sameBaseHitsTheCache() throws {
        TextLayoutCache.shared.store(layout("hello"), for: try key())
        XCTAssertEqual(TextLayoutCache.shared.layout(for: try key())?.lines.first?.text, "hello")
    }

    /// The enhanced base is a different image with different text positions.
    func test_enhancedBaseDoesNotShareWithSource() throws {
        TextLayoutCache.shared.store(layout("source"), for: try key())
        XCTAssertNil(TextLayoutCache.shared.layout(for: try key(enhanced: true)))
    }

    func test_cutoutBaseDoesNotShareWithSource() throws {
        TextLayoutCache.shared.store(layout("source"), for: try key())
        XCTAssertNil(TextLayoutCache.shared.layout(for: try key(cutout: true)))
    }

    /// Cropping changes the coordinate space the boxes are normalized against.
    func test_croppedBaseDoesNotShareWithUncropped() throws {
        TextLayoutCache.shared.store(layout("full"), for: try key())
        XCTAssertNil(TextLayoutCache.shared.layout(
            for: try key(crop: CGRect(x: 0, y: 0, width: 10, height: 10))))
    }

    func test_differentDimensionsDoNotShare() throws {
        TextLayoutCache.shared.store(layout("small"), for: try key())
        XCTAssertNil(TextLayoutCache.shared.layout(
            for: try key(size: CGSize(width: 200, height: 100))))
    }

    /// The most dangerous case: a destructive edit is saved, so the SAME URL
    /// now holds different pixels. The manifest's stamp is what catches it.
    func test_rewritingTheCaptureInvalidatesTheEntry() throws {
        TextLayoutCache.shared.store(layout("before"), for: try key())
        try writePackage(at: url, red: 1)   // a real save: manifest stamp moves
        XCTAssertNil(TextLayoutCache.shared.layout(for: try key()),
                     "a rewritten capture must not reuse the old text geometry")
    }

    /// The whole point of the disk tier: quitting must not cost a re-recognition.
    func test_survivesLosingTheInMemoryTier() throws {
        TextLayoutCache.shared.store(layout("persisted"), for: try key())
        TextLayoutCache.shared.removeAll()   // stands in for a relaunch
        XCTAssertEqual(TextLayoutCache.shared.layout(for: try key())?.lines.first?.text,
                       "persisted")
    }

    /// Bounded so revisiting captures cannot grow memory without limit.
    func test_evictsOldestBeyondTheLimit() throws {
        var urls: [URL] = []
        for i in 0..<12 {
            let u = FileManager.default.temporaryDirectory
                .appendingPathComponent("evict-\(UUID().uuidString)-\(i).seal")
            try writePackage(at: u)
            urls.append(u)
            TextLayoutCache.shared.store(layout("n\(i)"), for: try key(at: u),
                                         persist: false)
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Nothing to assert about WHICH survive beyond boundedness; storing 12
        // into a cache of 8 must not retain all 12. `persist: false` above keeps
        // this about the memory tier — with the disk tier every one would hit.
        var survivors = 0
        for u in urls where TextLayoutCache.shared.layout(for: try key(at: u)) != nil {
            survivors += 1
        }
        XCTAssertLessThanOrEqual(survivors, 8)
    }
}
