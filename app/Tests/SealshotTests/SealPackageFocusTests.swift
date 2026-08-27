import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class SealPackageFocusTests: XCTestCase {
    func testWriteReadRoundTripsFocus() throws {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let focus = CGRect(x: 2, y: 3, width: 10, height: 8)
        try writeSealPackage(to: dir, source: img, composite: img,
                             annotations: [], crop: nil, focus: focus,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let read = try readSealPackage(at: dir, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(read.focus, focus)
    }
}
