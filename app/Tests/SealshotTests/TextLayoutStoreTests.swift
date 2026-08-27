import XCTest
import CoreGraphics
@testable import Sealshot

/// The disk half of the Live Text cache: a layout survives quitting the app.
///
/// `TextLayoutCache` keeps layouts for the life of the process, which covers
/// switching captures and coming back. Everything is thrown away on quit, so
/// the first use of Live Text or Find in Image after a relaunch pays a full
/// recognition pass — ~10s on a Mac with no Neural Engine — for a result the
/// app already computed. This is where that result is written down.
@MainActor
final class TextLayoutStoreTests: XCTestCase {

    var url: URL!
    var plain: SealPackageCryptoContext { SealPackageCryptoContext(publicKey: nil, identity: nil) }

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-store-\(UUID().uuidString).seal")
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        _ = try writeSealPackage(to: url, source: img, composite: img, annotations: [],
                                 crop: nil, crypto: plain)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: url) }

    private func layout(_ text: String = "Invoice") -> RecognizedTextLayout {
        RecognizedTextLayout(lines: [
            RecognizedLine(text: text,
                           box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05),
                           charBoxes: [], quad: nil)
        ])
    }

    private func key(base: DerivedBase = .source, crop: CGRect? = nil) throws -> TextLayoutKey {
        let anchor = try XCTUnwrap(derivedAnchor(for: url, crypto: plain))
        return TextLayoutKey(sourceURL: url, base: base, crop: crop,
                             width: 8, height: 8, anchor: anchor)
    }

    func test_savedLayoutComesBack() throws {
        let k = try key()
        TextLayoutStore.save(layout(), for: k, crypto: plain)
        let loaded = try XCTUnwrap(TextLayoutStore.load(for: k, crypto: plain))
        XCTAssertEqual(loaded.lines.first?.text, "Invoice")
    }

    func test_nothingSavedYieldsNil() throws {
        XCTAssertNil(TextLayoutStore.load(for: try key(), crypto: plain))
    }

    func test_emptyLayoutIsRemembered() throws {
        // "This capture has no text" is the most valuable thing to persist:
        // without it, every launch pays a full pass to learn nothing.
        let k = try key()
        TextLayoutStore.save(RecognizedTextLayout(lines: []), for: k, crypto: plain)
        let loaded = try XCTUnwrap(TextLayoutStore.load(for: k, crypto: plain),
                                   "an empty result must be a stored answer, not an absent one")
        XCTAssertTrue(loaded.isEmpty)
    }

    func test_aRealSaveInvalidatesTheLayout() throws {
        let k = try key()
        TextLayoutStore.save(layout(), for: k, crypto: plain)

        // Re-save the package the way an edit would: the manifest's stamp moves.
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        _ = try writeSealPackage(to: url, source: ctx.makeImage()!, composite: ctx.makeImage()!,
                                 annotations: [], crop: nil, crypto: plain)

        let fresh = try key()
        XCTAssertNil(TextLayoutStore.load(for: fresh, crypto: plain),
                     "boxes from the old pixels must not be served for the new ones")
    }

    func test_writingTheLayoutDoesNotInvalidateIt() throws {
        // The trap this design exists to avoid: the sidecar write changing the
        // package's mtime, so the layout goes stale the moment it is stored.
        let k = try key()
        TextLayoutStore.save(layout(), for: k, crypto: plain)

        let reread = try key()
        XCTAssertNotNil(TextLayoutStore.load(for: reread, crypto: plain))
    }

    func test_basesDoNotShareALayout() throws {
        TextLayoutStore.save(layout("source text"), for: try key(base: .source), crypto: plain)
        TextLayoutStore.save(layout("enhanced text"), for: try key(base: .enhanced), crypto: plain)

        XCTAssertEqual(try XCTUnwrap(TextLayoutStore.load(for: key(base: .source), crypto: plain))
                        .lines.first?.text, "source text")
        XCTAssertEqual(try XCTUnwrap(TextLayoutStore.load(for: key(base: .enhanced), crypto: plain))
                        .lines.first?.text, "enhanced text")
    }

    func test_cropsDoNotShareALayout() throws {
        let cropped = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        TextLayoutStore.save(layout("whole"), for: try key(), crypto: plain)
        XCTAssertNil(TextLayoutStore.load(for: try key(crop: cropped), crypto: plain))
    }

    func test_savingASecondBaseKeepsTheFirst() throws {
        // Sections share one file, so writing one must be a merge, not a
        // replace.
        TextLayoutStore.save(layout("first"), for: try key(base: .source), crypto: plain)
        TextLayoutStore.save(layout("second"), for: try key(base: .cutout), crypto: plain)
        XCTAssertNotNil(TextLayoutStore.load(for: try key(base: .source), crypto: plain))
    }
}
