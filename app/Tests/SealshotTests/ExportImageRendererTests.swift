import XCTest
import CryptoKit
@testable import Sealshot

@MainActor
final class ExportImageRendererTests: XCTestCase {

    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func tempSeal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("export-img-\(UUID().uuidString).seal")
    }
    private func imageSource(_ url: URL) -> SharePackageSource {
        SharePackageSource(url: url,
                           displayName: url.deletingPathExtension().lastPathComponent,
                           isVideo: false)
    }
    private let pngMagic: [UInt8] = [0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]

    func testPlaintextImageRendersFullResPNG() async throws {
        let url = tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let img = makeImage(width: 24, height: 16)
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil,
                                 crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let data = try await ExportImageRenderer.pngData(
            for: imageSource(url),
            crypto: SealPackageCryptoContext(publicKey: nil, identity: nil),
            recordingsKey: nil)
        XCTAssertEqual(Array(data.prefix(8)), pngMagic)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(cg.width, 24)
        XCTAssertEqual(cg.height, 16)
    }

    func testLockedImageThrowsWithoutIdentityAndSucceedsWith() async throws {
        let identity = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: identity.publicKey)
        let writeOnly = SealPackageCryptoContext(publicKey: identity.publicKey, generation: gen, identity: nil)
        let full = SealPackageCryptoContext(publicKey: identity.publicKey, generation: gen, identity: identity)
        let url = tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let img = makeImage(width: 10, height: 10)
        _ = try writeSealPackage(to: url, source: img, composite: img,
                                 annotations: [], crop: nil, crypto: writeOnly)

        do {
            _ = try await ExportImageRenderer.pngData(for: imageSource(url), crypto: writeOnly, recordingsKey: nil)
            XCTFail("expected ExportImageError.locked")
        } catch ExportImageError.locked { /* expected */ }

        let data = try await ExportImageRenderer.pngData(for: imageSource(url), crypto: full, recordingsKey: nil)
        XCTAssertEqual(Array(data.prefix(8)), pngMagic)
    }

    func testUniqueNameDedupesForFolderExport() {
        var used: Set<String> = ["shot.png"]
        let n1 = CaptureConfig.uniqueName(base: "shot", ext: "png") { used.contains($0) }
        XCTAssertEqual(n1, "shot 2.png")
        used.insert(n1)
        let n2 = CaptureConfig.uniqueName(base: "shot", ext: "png") { used.contains($0) }
        XCTAssertEqual(n2, "shot 3.png")
    }
}
