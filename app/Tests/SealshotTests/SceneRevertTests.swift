import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class SceneRevertTests: XCTestCase {

    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func imageAnn(_ rect: CGRect, _ id: String) -> Annotation {
        Annotation(geometry: .image(rect: rect, assetID: id),
                   style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))
    }

    /// A Live Capture scene: revert restores the window layers to their captured
    /// frames (keeping stacking order) and drops annotations drawn on top.
    func testSceneRevert_restoresLayoutAndDropsDrawnEdits() throws {
        let state = EditorState(sourceImage: image(1200, 800), sourceURL:
            URL(fileURLWithPath: "/tmp/scene.seal"))
        // Two window layers, currently MOVED from their captured positions.
        state.annotations = [imageAnn(CGRect(x: 500, y: 500, width: 300, height: 200), "w1"),
                             imageAnn(CGRect(x: 900, y: 10, width: 200, height: 150), "w2")]
        state.registerImageAsset(id: "w1", data: Data([1, 2, 3]))
        state.registerImageAsset(id: "w2", data: Data([4, 5, 6]))
        // Drawn-on-top annotation that revert must drop.
        state.annotations.append(Annotation(
            geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 50, height: 50)),
            style: Style(strokeColor: SerializableColor(NSColor.red), strokeWidth: 2)))
        // Captured (original) frames.
        let orig: [String: CGRect] = [
            "w1": CGRect(x: 0, y: 0, width: 300, height: 200),
            "w2": CGRect(x: 320, y: 0, width: 200, height: 150)]
        state.sceneOriginalFrames = orig

        let reverted = state.revertedToOriginal()

        // Only the two image layers survive, at their captured frames, z-order kept.
        XCTAssertEqual(reverted.annotations.count, 2)
        guard case let .image(r1, id1) = reverted.annotations[0].geometry,
              case let .image(r2, id2) = reverted.annotations[1].geometry else {
            return XCTFail("expected two .image layers")
        }
        XCTAssertEqual(id1, "w1"); XCTAssertEqual(r1, orig["w1"])
        XCTAssertEqual(id2, "w2"); XCTAssertEqual(r2, orig["w2"])
        // Assets carried; still recognized as a scene.
        XCTAssertEqual(reverted.imageAssets.keys.sorted(), ["w1", "w2"])
        XCTAssertEqual(reverted.sceneOriginalFrames, orig)
    }

    /// A non-scene capture: revert keeps its plain behavior — a pristine base
    /// with NO annotations.
    func testNonSceneRevert_dropsAllAnnotations() {
        let state = EditorState(sourceImage: image(400, 300), sourceURL: nil)
        state.annotations = [Annotation(
            geometry: .rectangle(rect: CGRect(x: 1, y: 1, width: 10, height: 10)),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 1))]
        // sceneOriginalFrames stays empty → not a scene.
        let reverted = state.revertedToOriginal()
        XCTAssertTrue(reverted.annotations.isEmpty, "non-scene revert clears annotations")
    }

    /// REGRESSION (restart bug): a scene reopened from disk must rehydrate
    /// `sceneOriginalFrames` from manifest.sceneLayers — without it, Revert to
    /// Original wiped the window layers to an empty canvas after an app
    /// restart. Pins the write → read → hydrate → revert loop end to end.
    func testReopenedScene_revertRestoresLayout() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: url) }
        let base = image(1200, 800)
        let orig = CGRect(x: 40, y: 60, width: 300, height: 200)
        let moved = CGRect(x: 700, y: 500, width: 300, height: 200)
        let layer = SceneLayer(assetID: "w1", app: "Finder", title: "Desktop",
                               bundleID: "com.apple.finder", originalFrame: orig, z: 0)
        try writeSealPackage(to: url, source: base, composite: base,
                             annotations: [imageAnn(moved, "w1")], crop: nil,
                             assets: ["w1": Data([9, 9])],
                             captureKind: .liveCapture, sceneLayers: [layer],
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        // "Restart": everything rebuilt from disk, as EditorController's open
        // path does — including the sceneOriginalFrames hydration under test.
        let pkg = try readSealPackage(
            at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let state = EditorState(sourceImage: pkg.source, sourceURL: url)
        state.annotations = pkg.annotations
        state.imageAssets = pkg.imageAssets
        state.sceneOriginalFrames = SceneLayer.originalFrames(from: pkg.manifest.sceneLayers)

        let reverted = state.revertedToOriginal()
        XCTAssertEqual(reverted.annotations.count, 1,
                       "reopened scene must keep its window layer on revert, not wipe to empty")
        guard case let .image(rect, id) = reverted.annotations[0].geometry else {
            return XCTFail("expected the window image layer")
        }
        XCTAssertEqual(id, "w1")
        XCTAssertEqual(rect, orig, "layer must return to its captured frame")
        XCTAssertFalse(reverted.sceneOriginalFrames.isEmpty, "scene identity survives revert")
    }

    /// REGRESSION (data loss): the autosave after ANY revert must keep the
    /// asset bytes — a revert that drops image annotations must not also
    /// strip asset-*.png from the package on the next save.
    func testRevert_alwaysCarriesImageAssetBytes() {
        let state = EditorState(sourceImage: image(400, 300), sourceURL: nil)
        state.annotations = [imageAnn(CGRect(x: 5, y: 5, width: 50, height: 40), "w1")]
        state.registerImageAsset(id: "w1", data: Data([7, 7, 7]))
        // NOT a scene (no sceneOriginalFrames) — plain revert drops the
        // annotation, but the bytes must survive for recovery/undo.
        let reverted = state.revertedToOriginal()
        XCTAssertTrue(reverted.annotations.isEmpty)
        XCTAssertEqual(reverted.imageAssets["w1"], Data([7, 7, 7]),
                       "asset bytes must never be pruned by a revert")
    }
}
