import XCTest
@testable import Sealshot

@MainActor
final class SceneComposerTests: XCTestCase {

    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testLayerRectsAndZOrder() throws {
        // scale 2; union origin at (-100, -50). Two windows.
        let front = CapturedWindow(image: image(200, 100),
            globalFrame: CGRect(x: 0, y: 0, width: 100, height: 50), z: 0,
            app: "Front", bundleID: "f", title: "Front")
        let back = CapturedWindow(image: image(100, 100),
            globalFrame: CGRect(x: -100, y: -50, width: 50, height: 50), z: 1,
            app: "Back", bundleID: "b", title: "Back")
        let result = SceneCaptureResult(
            windows: [front, back],
            displays: [CapturedDisplay(wallpaper: image(300, 200),
                globalFrame: CGRect(x: -100, y: -50, width: 150, height: 100))],
            scale: 2, skippedCount: 0)

        let scene = try SceneComposer.compose(result)

        // union = windows ∪ display: minX-100,minY-50,maxX 100 (front sticks out),
        // maxY 50 → 200x100 pts × scale 2 = 400x200 px.
        XCTAssertEqual(scene.sourceSize, CGSize(width: 400, height: 200))
        // layers stored back-to-front: [back, front]; last = topmost = front.
        XCTAssertEqual(scene.layers.count, 2)
        guard case let .image(frontRect, frontID) = scene.layers[1].geometry,
              case let .image(backRect, backID) = scene.layers[0].geometry else {
            return XCTFail("expected .image geometries")
        }
        // front origin = (0-(-100), 0-(-50)) * 2 = (200,100); size = image px (200,100)
        XCTAssertEqual(frontRect, CGRect(x: 200, y: 100, width: 200, height: 100))
        // back origin = (0,0)*2 = (0,0); size = (100,100)
        XCTAssertEqual(backRect, CGRect(x: 0, y: 0, width: 100, height: 100))
        // originalFrames + sceneLayers carry the same rects + metadata
        XCTAssertEqual(scene.originalFrames[frontID], frontRect)
        XCTAssertEqual(scene.originalFrames[backID], backRect)
        XCTAssertEqual(scene.sceneLayers.first(where: { $0.assetID == frontID })?.app, "Front")
        XCTAssertEqual(scene.sceneLayers.first(where: { $0.assetID == frontID })?.z, 0)
        XCTAssertEqual(scene.assets.count, 2)
    }

    func testEmptyWindowsThrows() {
        let result = SceneCaptureResult(windows: [], displays: [], scale: 1, skippedCount: 0)
        XCTAssertThrowsError(try SceneComposer.compose(result))
    }
}
