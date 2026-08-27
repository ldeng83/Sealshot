import Foundation
import CoreGraphics
@testable import Sealshot

/// Shared helper for tests that need a real `.seal` package on disk.
/// Produces a PLAINTEXT (unencrypted) package so it can be read back without keys.
@MainActor
enum TestSealFactory {

    /// Write a minimal 4×4 pixel `.seal` with `metadata` pre-applied and return its URL.
    /// The caller is responsible for deleting the directory when done.
    static func makePlaintextSeal(metadata: CaptureMetadata) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-\(UUID().uuidString).seal")
        let image = makeMinimalImage()
        let crypto = SealPackageCryptoContext(publicKey: nil, identity: nil)
        try writeSealPackage(to: url, source: image, composite: image,
                             annotations: [], crop: nil, crypto: crypto)
        try SealMetadataStore.apply(metadata: metadata, sourceApp: nil, to: url)
        return url
    }

    // MARK: private

    private static func makeMinimalImage() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}
