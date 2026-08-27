import XCTest
import CoreGraphics
@testable import Sealshot

/// Display name = the manual user title if set, else the filename without its
/// extension (the deterministic `<window/app> <timestamp>` scheme lives in the
/// filename itself now).
@MainActor
final class CaptureDisplayNameTests: XCTestCase {

    private func tempURL(_ ext: String, name: String = "cap") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)")
    }
    private func img() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func writeSeal(_ url: URL, userTitle: String?) throws {
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let meta = CaptureMetadata(generatedTitle: "Some OCR Guess", userTitle: userTitle,
                                   tags: [], category: .error, confidence: 0.55, generatorVersion: 2)
        try SealMetadataStore.apply(metadata: meta, sourceApp: "Google Chrome", to: url)
    }

    func testNoUserTitle_returnsFilenameWithoutExtension() throws {
        let url = tempURL("seal"); defer { try? FileManager.default.removeItem(at: url) }
        try writeSeal(url, userTitle: nil)
        XCTAssertEqual(CaptureDisplayName.resolve(for: url), url.deletingPathExtension().lastPathComponent)
    }

    func testUserTitle_wins() throws {
        let url = tempURL("seal"); defer { try? FileManager.default.removeItem(at: url) }
        try writeSeal(url, userTitle: "My Title")
        XCTAssertEqual(CaptureDisplayName.resolve(for: url), "My Title")
    }

    func testWhitespaceUserTitle_treatedAsAbsent() throws {
        let url = tempURL("seal"); defer { try? FileManager.default.removeItem(at: url) }
        try writeSeal(url, userTitle: "   \n")
        XCTAssertEqual(CaptureDisplayName.resolve(for: url), url.deletingPathExtension().lastPathComponent)
    }

    func testSealWithoutMetadata_returnsFilenameWithoutExtension() throws {
        let url = tempURL("seal"); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                        crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(CaptureDisplayName.resolve(for: url), url.deletingPathExtension().lastPathComponent)
    }

    func testNonSealFile_returnsFilenameWithoutExtension() {
        let url = URL(fileURLWithPath: "/tmp/Google Chrome 2026-06-09 at 09_09_10.png")
        XCTAssertEqual(CaptureDisplayName.resolve(for: url), "Google Chrome 2026-06-09 at 09_09_10")
    }
}
