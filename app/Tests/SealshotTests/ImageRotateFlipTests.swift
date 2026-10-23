import XCTest
@testable import Sealshot

/// Image ▸ Rotate / Flip: the orientation algebra, exact pixel moves, where
/// annotations land, and that the original pixels survive save + revert.
@MainActor
final class ImageRotateFlipTests: XCTestCase {

    // MARK: - Fixtures

    /// A `w`×`h` image whose every pixel has a distinct color, so any wrong
    /// move shows up. Pixel (x, y) is in image space (top-left origin).
    private func patterned(_ w: Int = 3, _ h: Int = 2) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<h {
            for x in 0..<w {
                ctx.setFillColor(CGColor(red: CGFloat(x + 1) / CGFloat(w + 1),
                                         green: CGFloat(y + 1) / CGFloat(h + 1), blue: 0.5, alpha: 1))
                ctx.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))   // CG is y-up
            }
        }
        return ctx.makeImage()!
    }

    /// RGBA bytes of `image`, row-major from the top.
    private func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let p = pixels(image), i = (y * image.width + x) * 4
        return Array(p[i..<i + 4])
    }

    private func apply(_ steps: [ImageOrientationStep], to image: CGImage) -> CGImage {
        steps.reduce(image) { ImageOrientationRenderer.apply($1, to: $0)! }
    }

    private let allSteps = ImageOrientationStep.allCases

    /// All eight orientations.
    private var allOrientations: [ImageOrientation] {
        (0..<4).flatMap { k in [false, true].map { ImageOrientation(quarterTurns: k, mirrored: $0) } }
    }

    private func style() -> Style { Style(strokeColor: SerializableColor(.red), strokeWidth: 2) }

    // MARK: - Orientation algebra

    func testStepCyclesReturnToIdentity() {
        XCTAssertEqual((0..<4).reduce(ImageOrientation.identity) { o, _ in o.then(.rotateRight) }, .identity)
        XCTAssertEqual(ImageOrientation.identity.then(.rotateRight).then(.rotateLeft), .identity)
        XCTAssertEqual(ImageOrientation.identity.then(.flipHorizontal).then(.flipHorizontal), .identity)
        XCTAssertEqual(ImageOrientation.identity.then(.flipVertical).then(.flipVertical), .identity)
        XCTAssertEqual(ImageOrientation.identity.then(.flipHorizontal).then(.flipVertical),
                       ImageOrientation(quarterTurns: 2), "both mirrors make a half turn")
    }

    func testInverseAndRelative() {
        for o in allOrientations {
            XCTAssertEqual(ImageOrientation.compose(o, then: o.inverse), .identity, "\(o)")
            for target in allOrientations {
                XCTAssertEqual(ImageOrientation.compose(o, then: o.relative(to: target)), target)
            }
        }
    }

    /// `then` must describe what the pixels actually do.
    func testThenMatchesPixels() {
        let img = patterned()
        for o in allOrientations {
            let oriented = ImageOrientationRenderer.apply(o, to: img)!
            for step in allSteps {
                let expected = ImageOrientationRenderer.apply(o.then(step), to: img)!
                let actual = ImageOrientationRenderer.apply(step, to: oriented)!
                XCTAssertEqual(pixels(actual), pixels(expected), "\(o) then \(step)")
            }
        }
    }

    // MARK: - Pixels

    func testRotateRightMovesPixelsClockwise() {
        let img = patterned(3, 2)
        let r = ImageOrientationRenderer.apply(.rotateRight, to: img)!
        XCTAssertEqual(r.width, 2)
        XCTAssertEqual(r.height, 3)
        // Clockwise: source (x, y) lands at (H-1-y, x).
        for y in 0..<2 { for x in 0..<3 {
            XCTAssertEqual(pixel(r, 1 - y, x), pixel(img, x, y), "(\(x),\(y))")
        } }
    }

    func testFlipsMirrorPixels() {
        let img = patterned(3, 2)
        let h = ImageOrientationRenderer.apply(.flipHorizontal, to: img)!
        let v = ImageOrientationRenderer.apply(.flipVertical, to: img)!
        for y in 0..<2 { for x in 0..<3 {
            XCTAssertEqual(pixel(h, 2 - x, y), pixel(img, x, y))
            XCTAssertEqual(pixel(v, x, 1 - y), pixel(img, x, y))
        } }
    }

    func testFourQuarterTurnsAreLossless() {
        let img = patterned(5, 3)
        XCTAssertEqual(pixels(apply(Array(repeating: .rotateRight, count: 4), to: img)), pixels(img))
        XCTAssertEqual(pixels(apply([.flipHorizontal, .flipHorizontal], to: img)), pixels(img))
    }

    // MARK: - Annotations

    func testRectangleMapsAndSwapsUnderRotation() {
        let a = Annotation(geometry: .rectangle(rect: CGRect(x: 10, y: 5, width: 20, height: 10)), style: style())
        let out = ImageOrientationMath.annotations([a], after: .rotateRight, in: CGSize(width: 100, height: 50))[0]
        // Clockwise in a 100×50 image: x' = H − maxY, y' = minX, sides swap.
        XCTAssertEqual(out.geometry, .rectangle(rect: CGRect(x: 35, y: 10, width: 10, height: 20)))
        XCTAssertEqual(out.id, a.id)
    }

    func testArrowEndpointsMap() {
        let a = Annotation(geometry: .arrow(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 60, y: 40)), style: style())
        let out = ImageOrientationMath.annotations([a], after: .flipHorizontal, in: CGSize(width: 100, height: 50))[0]
        XCTAssertEqual(out.geometry, .arrow(start: CGPoint(x: 90, y: 20), end: CGPoint(x: 40, y: 40)))
    }

    func testTextMovesButStaysUpright() {
        let runs = [TextRun(text: "Hi", color: SerializableColor(.black), fontSize: 18, isBold: false)]
        let a = Annotation(geometry: .text(rect: CGRect(x: 10, y: 10, width: 40, height: 20), runs: runs), style: style())
        for step in allSteps {
            let out = ImageOrientationMath.annotations([a], after: step, in: CGSize(width: 100, height: 50))[0]
            guard case let .text(rect, outRuns) = out.geometry else { return XCTFail("kind changed") }
            XCTAssertEqual(rect.size, CGSize(width: 40, height: 20), "\(step): text is not stretched or turned")
            XCTAssertEqual(out.transform, a.transform, "\(step): no rotation or mirror")
            XCTAssertEqual(outRuns, runs)
            let centre = CGPoint(x: 30, y: 20).applying(step.transform(for: CGSize(width: 100, height: 50)))
            XCTAssertEqual(rect.midX, centre.x, accuracy: 0.001)
            XCTAssertEqual(rect.midY, centre.y, accuracy: 0.001)
        }
    }

    func testImageLayerTurnsWithTheImage() {
        let a = Annotation(geometry: .image(rect: CGRect(x: 0, y: 0, width: 40, height: 20), assetID: "x"), style: style())
        let right = ImageOrientationMath.annotations([a], after: .rotateRight, in: CGSize(width: 100, height: 50))[0]
        XCTAssertEqual(right.transform.rotationDegrees, 90)
        guard case let .image(rect, _) = right.geometry else { return XCTFail() }
        XCTAssertEqual(rect.size, CGSize(width: 40, height: 20), "the bitmap keeps its own size; the transform turns it")
        let flipped = ImageOrientationMath.annotations([a], after: .flipHorizontal, in: CGSize(width: 100, height: 50))[0]
        XCTAssertTrue(flipped.transform.flipH)
    }

    /// The rendered shape (bounds + transform) must land exactly where the
    /// image's pixels went — checked on the corners of a rotated, flipped box.
    func testTransformedShapeCornersFollowTheImage() {
        let size = CGSize(width: 100, height: 50)
        let rect = CGRect(x: 20, y: 10, width: 30, height: 12)
        let a = Annotation(geometry: .rectangle(rect: rect), style: style(),
                           transform: AnnotationTransform(rotationDegrees: 25, flipH: true, flipV: false))
        func corners(_ ann: Annotation) -> [CGPoint] {
            guard case let .rectangle(r) = ann.geometry else { return [] }
            let m = transformMatrix(for: ann.transform, center: CGPoint(x: r.midX, y: r.midY))
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(m) }
        }
        for step in allSteps {
            let out = ImageOrientationMath.annotations([a], after: step, in: size)[0]
            let expected = Set(corners(a).map { $0.applying(step.transform(for: size)) }.map(rounded))
            XCTAssertEqual(Set(corners(out).map(rounded)), expected, "\(step)")
        }
    }

    private func rounded(_ p: CGPoint) -> String { String(format: "%.3f,%.3f", p.x, p.y) }

    /// A redaction must keep covering the same pixels: paint the blur rect's
    /// area, turn the PIXELS, and compare with where the annotation went.
    func testBlurRegionStillCoversTheSamePixels() {
        let w = 40, h = 24
        let region = CGRect(x: 5, y: 3, width: 12, height: 7)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.black); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: region.minX, y: CGFloat(h) - region.maxY, width: region.width, height: region.height))
        let img = ctx.makeImage()!
        let blur = Annotation(geometry: .blur(region: .rect(region)), style: style())
        for step in allSteps {
            let turned = ImageOrientationRenderer.apply(step, to: img)!
            let p = pixels(turned)
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<turned.height { for x in 0..<turned.width where p[(y * turned.width + x) * 4] > 128 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            } }
            let painted = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            let out = ImageOrientationMath.annotations([blur], after: step, in: CGSize(width: w, height: h))[0]
            XCTAssertEqual(out.geometry, .blur(region: .rect(painted)), "\(step)")
        }
    }

    // MARK: - Document

    func testReorientedDocumentMatchesTurningTheVisibleImage() {
        let state = EditorState(sourceImage: patterned(8, 5), sourceURL: nil)
        let crop = CGRect(x: 1, y: 1, width: 5, height: 3)
        state.croppedRect = crop
        let visible = state.sourceImage.cropping(to: crop)!
        for step in allSteps {
            let next = state.reoriented(by: step)!
            let nextVisible = next.sourceImage.cropping(to: next.croppedRect!)!
            XCTAssertEqual(pixels(nextVisible), pixels(ImageOrientationRenderer.apply(step, to: visible)!),
                           "\(step): the crop maps with the pixels")
            XCTAssertEqual(next.orientation, ImageOrientation.identity.then(step))
            XCTAssertTrue(next.hasEdits)
        }
    }

    func testOriginalPixelsArePersistedAndRevertUndoesTheTurn() {
        let original = patterned(4, 3)
        let state = EditorState(sourceImage: original, sourceURL: nil)
        let turned = state.reoriented(by: .rotateRight)!.reoriented(by: .flipHorizontal)!
        XCTAssertEqual(turned.sourceImage.width, 3)
        XCTAssertEqual(pixels(turned.persistedSourceImage), pixels(original), "source.png keeps the original")
        let reverted = turned.revertedToOriginal()
        XCTAssertEqual(reverted.orientation, .identity)
        XCTAssertEqual(pixels(reverted.sourceImage), pixels(original))
    }

    func testResizedDocumentTurnsItsPristineToo() {
        let pristine = patterned(8, 4)
        let resized = DocumentResampler.resample(pristine, to: CGSize(width: 4, height: 2))!
        let state = EditorState(sourceImage: resized, sourceURL: nil, pristineSource: pristine)
        let next = state.reoriented(by: .rotateLeft)!
        XCTAssertEqual(next.sourceImage.width, 2)
        XCTAssertEqual(next.orientedPristine.width, 4)
        XCTAssertEqual(next.orientedPristine.height, 8)
        XCTAssertEqual(next.resizeFactors.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(pixels(next.persistedSourceImage), pixels(pristine))
    }

    func testSnapshotAcrossAnOrientationRequiresRebuild() {
        let state = EditorState(sourceImage: patterned(4, 4), sourceURL: nil)
        let before = state.makeSnapshot(action: "x")
        let flipped = state.reoriented(by: .flipHorizontal)!   // same size
        XCTAssertTrue(flipped.snapshotRequiresRebuild(before), "a flip keeps the size, so size alone can't tell")
        XCTAssertFalse(flipped.snapshotRequiresRebuild(flipped.makeSnapshot(action: "y")))
    }

    /// End to end through the window controller: one step per action, ⌘Z
    /// back to the exact original, ⌘⇧Z forward again.
    func testControllerRotateThenUndoAndRedo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImageRotateFlipUndo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("u.seal")
        let original = patterned(6, 4)
        let crypto = SealPackageCryptoContext(publicKey: nil, identity: nil)
        try writeSealPackage(to: url, source: original, composite: original, annotations: [],
                             crop: nil, crypto: crypto)
        let state = EditorState(sourceImage: original, sourceURL: url)
        state.annotations = [Annotation(geometry: .rectangle(rect: CGRect(x: 1, y: 1, width: 2, height: 1)),
                                        style: style())]
        let config = CaptureConfig()
        let controller = EditorWindowController(
            state: state, saver: EditorSaveCoordinator(config: config), config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "orient-undo", onRecentClick: { _ in })

        controller.applyImageOrientation(.rotateRight)
        let turned = try XCTUnwrap(controller.state)
        XCTAssertEqual(turned.orientation, ImageOrientation(quarterTurns: 1))
        XCTAssertEqual(turned.sourceImage.width, 4)
        XCTAssertEqual(turned.annotations[0].geometry, .rectangle(rect: CGRect(x: 2, y: 1, width: 1, height: 2)))

        controller.handleUndo()
        let back = try XCTUnwrap(controller.state)
        XCTAssertEqual(back.orientation, .identity)
        XCTAssertEqual(pixels(back.sourceImage), pixels(original), "⌘Z restores the exact pixels")
        XCTAssertEqual(back.annotations[0].geometry, .rectangle(rect: CGRect(x: 1, y: 1, width: 2, height: 1)))

        controller.handleRedo()
        XCTAssertEqual(controller.state?.orientation, ImageOrientation(quarterTurns: 1))
        XCTAssertEqual(controller.state?.sourceImage.width, 4)
    }

    func testResetOrientationRestoresPixelsAndKeepsOtherEdits() {
        let original = patterned(6, 4)
        let state = EditorState(sourceImage: original, sourceURL: nil)
        let box = CGRect(x: 1, y: 1, width: 2, height: 1)
        state.annotations = [Annotation(geometry: .rectangle(rect: box), style: style())]
        state.backgroundFill = SerializableColor(.blue)
        let turned = state.reoriented(by: .rotateRight)!.reoriented(by: .flipVertical)!
            .reoriented(by: .rotateRight)!
        let reset = turned.reoriented(to: .identity)!
        XCTAssertEqual(reset.orientation, .identity)
        XCTAssertNil(reset.unorientedSource)
        XCTAssertEqual(pixels(reset.sourceImage), pixels(original))
        XCTAssertEqual(reset.annotations[0].geometry, .rectangle(rect: box), "the box comes home too")
        XCTAssertEqual(reset.backgroundFill, SerializableColor(.blue), "other edits are kept, unlike Revert")
        XCTAssertTrue(state.reoriented(to: .identity) === state, "already upright: nothing to do")
    }

    func testControllerResetIsOneUndoStep() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImageRotateFlipReset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.seal")
        let original = patterned(6, 4)
        try writeSealPackage(to: url, source: original, composite: original, annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let config = CaptureConfig()
        let controller = EditorWindowController(
            state: EditorState(sourceImage: original, sourceURL: url),
            saver: EditorSaveCoordinator(config: config), config: config,
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            title: "orient-reset", onRecentClick: { _ in })
        controller.applyImageOrientation(.rotateLeft)
        controller.applyImageOrientation(.flipHorizontal)
        let turned = try XCTUnwrap(controller.state?.orientation)

        controller.resetImageOrientation()
        XCTAssertEqual(controller.state?.orientation, .identity)
        XCTAssertEqual(pixels(try XCTUnwrap(controller.state?.sourceImage)), pixels(original))

        controller.handleUndo()
        XCTAssertEqual(controller.state?.orientation, turned, "one ⌘Z undoes the whole reset")
    }

    // MARK: - Persistence

    func testCodecWritesOrientationOnlyWhenTurned() throws {
        struct Probe: Decodable { let version: Int }
        let plain = try encodeAnnotations([], crop: nil)
        XCTAssertEqual(try JSONDecoder().decode(Probe.self, from: plain).version, 12,
                       "unturned files stay readable by builds without orientation")
        XCTAssertEqual(try decodeAnnotations(from: plain).orientation, .identity)

        let o = ImageOrientation(quarterTurns: 3, mirrored: true)
        let turned = try encodeAnnotations([], crop: nil, orientation: o)
        XCTAssertEqual(try JSONDecoder().decode(Probe.self, from: turned).version, 13)
        XCTAssertEqual(try decodeAnnotations(from: turned).orientation, o)
    }

    /// A crafted annotations.json must not crash or stall the open: turns are
    /// normalized into 0...3 on decode.
    func testDecodingNormalizesOutOfRangeTurns() throws {
        for (raw, expected) in [(-1, 3), (5, 1), (Int.max, 3), (Int.min, 0)] {
            let json = #"{"version":13,"annotations":[],"orientation":{"quarterTurns":\#(raw),"mirrored":false}}"#
            let decoded = try decodeAnnotations(from: Data(json.utf8)).orientation
            XCTAssertEqual(decoded.quarterTurns, expected, "\(raw)")
            XCTAssertEqual(decoded.steps.count, expected)
        }
    }

    func testPackageRoundTripKeepsOriginalSourceAndOrientation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImageRotateFlip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.seal")
        let original = patterned(4, 3)
        let state = EditorState(sourceImage: original, sourceURL: nil).reoriented(by: .rotateRight)!
        let crypto = SealPackageCryptoContext(publicKey: nil, identity: nil)
        try writeSealPackage(to: url, source: state.persistedSourceImage, composite: state.sourceImage,
                             annotations: [], crop: nil, orientation: state.orientation, crypto: crypto)
        let contents = try readSealPackage(at: url, crypto: crypto)
        XCTAssertEqual(contents.orientation, ImageOrientation(quarterTurns: 1))
        XCTAssertEqual(pixels(contents.source), pixels(original), "source.png is never rewritten")
        XCTAssertEqual(pixels(ImageOrientationRenderer.apply(contents.orientation, to: contents.source)!),
                       pixels(state.sourceImage), "reopening rebuilds the turned document exactly")
    }
}
