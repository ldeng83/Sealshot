import XCTest
@testable import Sealshot

@MainActor
final class LiveCaptureWriterTests: XCTestCase {
    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func scene() throws -> ComposedScene {
        let w = CapturedWindow(image: image(40, 30),
            globalFrame: CGRect(x: 0, y: 0, width: 40, height: 30), z: 0,
            app: "A", bundleID: "a", title: "A")
        return try SceneComposer.compose(SceneCaptureResult(
            windows: [w],
            displays: [CapturedDisplay(wallpaper: image(40, 30),
                globalFrame: CGRect(x: 0, y: 0, width: 40, height: 30))],
            scale: 1, skippedCount: 0))
    }

    func testWriteReadRoundTrip() throws {
        let composed = try scene()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWriter-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: url) }
        try LiveCaptureWriter.write(composed, to: url,
            crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let contents = try readSealPackage(at: url,
            crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(contents.manifest.captureKind, .liveCapture)
        XCTAssertEqual(contents.manifest.sceneLayers?.count, 1)
        XCTAssertEqual(contents.imageAssets.count, 1)
        XCTAssertEqual(contents.annotations.count, 1)
    }

    func testMakeStatePopulatesLayersAndOriginals() throws {
        let composed = try scene()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x.seal")
        let state = LiveCaptureWriter.makeState(composed, url: url)
        XCTAssertEqual(state.annotations.count, 1)
        XCTAssertEqual(state.imageAssets.count, 1)
        XCTAssertEqual(state.sceneOriginalFrames.count, 1)   // added in Task 4
        XCTAssertEqual(state.sourceURL, url)
    }
}
