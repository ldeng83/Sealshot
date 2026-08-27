import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class SealPackageV2IOTests: XCTestCase {

    private func img(_ w: Int, _ h: Int) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    func testV2RoundTrip_storesEnhancedAndFlags() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = img(100, 80)
        try writeSealPackage(
            to: url, source: source, composite: source, annotations: [], crop: nil,
            enhanced: img(200, 160), showingEnhanced: true,
            crypto: SealPackageCryptoContext(publicKey: nil, identity: nil)
        )
        let pkg = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(pkg.manifest.version, SealManifest.currentVersion)
        XCTAssertEqual(pkg.enhanced?.width, 200)
        XCTAssertEqual(pkg.enhanced?.height, 160)
        XCTAssertTrue(pkg.showingEnhanced)
    }

    func testWithoutEnhanced_hasNilEnhanced() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2b-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = img(50, 50)
        try writeSealPackage(to: url, source: source, composite: source,
                             annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let pkg = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertNil(pkg.enhanced)
        XCTAssertFalse(pkg.showingEnhanced)
    }
}
