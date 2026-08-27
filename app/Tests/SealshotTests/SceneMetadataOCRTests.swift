import XCTest
import CoreGraphics
@testable import Sealshot

/// Live Capture scenes must be OCR'd per window, not over the `source` image —
/// `source` is the display wallpaper and has no readable text, which is why
/// scenes previously ended up with the terminal "OCR ran, no text" marker.
@MainActor
final class SceneMetadataOCRTests: XCTestCase {

    /// Distinguishable 1×1 images so the fake OCR closure can tell which asset
    /// it was handed by pixel value.
    private func image(gray: CGFloat) -> CGImage {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return ctx.makeImage()!
    }

    private func png(_ image: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])!
    }

    func test_sceneWindowTexts_readsAssetsNotSource() async throws {
        // Two windows, deliberately out of z order in the manifest.
        let layers = [
            SceneLayer(assetID: "back", app: "Terminal", title: "zsh",
                       bundleID: "com.apple.Terminal",
                       originalFrame: .zero, z: 1),
            SceneLayer(assetID: "front", app: "Safari", title: "Start",
                       bundleID: "com.apple.Safari",
                       originalFrame: .zero, z: 0),
        ]
        let assets: [String: Data] = [
            "front": png(image(gray: 0.25)),
            "back": png(image(gray: 0.75)),
        ]
        // Fake OCR: answers by asset, and returns nothing for the wallpaper —
        // if the implementation OCRs `source`, the result is empty and the test
        // fails, which is exactly the bug being fixed.
        let coordinator = MetadataCoordinator(ocr: { image in
            let sample = Self.grayValue(of: image)
            if sample < 0.5 { return [OCRLine(text: "Hello world", box: .zero)] }
            return [OCRLine(text: "make test", box: .zero)]
        })

        let windows = await coordinator.sceneWindowTexts(
            sceneLayers: layers, imageAssets: assets)

        XCTAssertEqual(windows.count, 2)
        let aggregate = SceneText.aggregate(windows)
        XCTAssertEqual(aggregate, """
        Safari — Start
        Hello world

        Terminal — zsh
        make test
        """)
    }

    /// A layer whose asset is missing from the package must not crash or
    /// fabricate a block — but it must NOT disappear either. Its app and title
    /// come from the manifest, not the bytes, so it still counts as a captured
    /// window and still earns a name-only bullet; only its text is empty.
    func test_sceneWindowTexts_missingAssetKeepsWindowWithNoText() async throws {
        let layers = [SceneLayer(assetID: "gone", app: "Notes", title: "",
                                 bundleID: "com.apple.Notes",
                                 originalFrame: .zero, z: 0)]
        let coordinator = MetadataCoordinator(ocr: { _ in
            XCTFail("must not OCR anything when the asset is absent")
            return []
        })
        let windows = await coordinator.sceneWindowTexts(
            sceneLayers: layers, imageAssets: [:])
        XCTAssertEqual(windows, [SceneWindowText(app: "Notes", title: "", z: 0, text: "")])
        // An empty-text window still adds nothing to the keyword text.
        XCTAssertEqual(SceneText.aggregate(windows), "")
    }

    private static func grayValue(of image: CGImage) -> CGFloat {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data), CFDataGetLength(data) > 0 else { return 1 }
        return CGFloat(ptr[0]) / 255.0
    }

    // MARK: - sceneAwareOCR(for:) routing

    /// Minimal `SealPackageContents` for routing tests: only `manifest`,
    /// `source`, and `imageAssets` matter to `sceneAwareOCR`.
    private func contents(manifest: SealManifest, source: CGImage,
                          imageAssets: [String: Data]) -> SealPackageContents {
        SealPackageContents(
            source: source, composite: source, annotations: [], crop: nil,
            contentClip: nil, focus: nil, resizedSize: nil, cutout: nil,
            showingCutout: false, backgroundFill: nil, manifest: manifest,
            enhanced: nil, showingEnhanced: false,
            enhancedAvailableUndecoded: false, imageAssets: imageAssets)
    }

    private func manifest(captureKind: CaptureKind?, sceneLayers: [SceneLayer]?) -> SealManifest {
        SealManifest(version: SealManifest.currentVersion,
                     createdISO8601: "2026-01-01T00:00:00Z",
                     modifiedISO8601: "2026-01-01T00:00:00Z",
                     sourceSize: .init(width: 1, height: 1),
                     sourceApp: nil,
                     captureKind: captureKind,
                     sceneLayers: sceneLayers)
    }

    /// A scene manifest with layers must route to the per-window assets, never
    /// to `source` (the wallpaper) — the constraint this whole fix protects.
    func test_sceneAwareOCR_sceneRoutesToWindowAssets() async throws {
        let layer = SceneLayer(assetID: "win", app: "Notes", title: "Shopping list",
                               bundleID: "com.apple.Notes", originalFrame: .zero, z: 0)
        let wallpaper = image(gray: 1.0)
        let windowPNG = png(image(gray: 0.1))
        let coordinator = MetadataCoordinator(ocr: { cgImage in
            if Self.grayValue(of: cgImage) > 0.9 {
                XCTFail("must never OCR the scene's wallpaper source")
                return []
            }
            return [OCRLine(text: "milk, eggs", box: .zero)]
        })
        let pkg = contents(manifest: manifest(captureKind: .liveCapture, sceneLayers: [layer]),
                           source: wallpaper, imageAssets: ["win": windowPNG])

        let result = await coordinator.sceneAwareOCR(for: pkg)

        XCTAssertTrue(result.text.contains("milk, eggs"))
        XCTAssertTrue(result.lines.isEmpty, "scene aggregate text carries no per-line boxes")
    }

    /// A non-scene manifest (nil captureKind, or anything other than
    /// `.liveCapture`) must still OCR `source` directly, unchanged behavior.
    func test_sceneAwareOCR_nonSceneOCRsSource() async throws {
        let source = image(gray: 0.5)
        let coordinator = MetadataCoordinator(ocr: { _ in
            [OCRLine(text: "regular screenshot text", box: .zero)]
        })
        let pkg = contents(manifest: manifest(captureKind: .screenshot, sceneLayers: nil),
                           source: source, imageAssets: [:])

        let result = await coordinator.sceneAwareOCR(for: pkg)

        XCTAssertEqual(result.text, "regular screenshot text")
        XCTAssertEqual(result.lines.count, 1)
    }

    /// A `.liveCapture` manifest with no scene layers (nil or empty) is not a
    /// scene in practice — it must fall through to OCR'ing `source` rather
    /// than silently producing nothing.
    func test_sceneAwareOCR_liveCaptureWithoutLayersFallsBackToSource() async throws {
        let source = image(gray: 0.5)
        let coordinator = MetadataCoordinator(ocr: { _ in
            [OCRLine(text: "fallback text", box: .zero)]
        })
        let nilLayers = contents(manifest: manifest(captureKind: .liveCapture, sceneLayers: nil),
                                 source: source, imageAssets: [:])
        let emptyLayers = contents(manifest: manifest(captureKind: .liveCapture, sceneLayers: []),
                                   source: source, imageAssets: [:])

        let nilResult = await coordinator.sceneAwareOCR(for: nilLayers)
        let emptyResult = await coordinator.sceneAwareOCR(for: emptyLayers)

        XCTAssertEqual(nilResult.text, "fallback text")
        XCTAssertEqual(emptyResult.text, "fallback text")
    }

    // MARK: - needsTagBackfill scene exemption

    /// The terminal marker exists to stop a pure image regenerating forever
    /// (capture while locked → unlock → generate → notify → generate…). For a
    /// scene it was never a real answer — it recorded that we OCR'd the
    /// wallpaper — so scenes get one exemption and nothing else does.
    func test_terminalMarker_isNotTerminalForScenes() {
        XCTAssertTrue(
            MetadataCoordinator.needsTagBackfill(
                smartKeywordsEmpty: true, ocrText: "", isScene: true),
            "a scene carrying the marker must be allowed to re-OCR its windows")
    }

    func test_terminalMarker_staysTerminalForOrdinaryCaptures() {
        XCTAssertFalse(
            MetadataCoordinator.needsTagBackfill(
                smartKeywordsEmpty: true, ocrText: "", isScene: false),
            "loop protection for pure images must be unchanged")
    }

    func test_existingKeywords_stillSuppressBackfill_forScenes() {
        XCTAssertFalse(
            MetadataCoordinator.needsTagBackfill(
                smartKeywordsEmpty: false, ocrText: "", isScene: true),
            "a scene that already has keywords must not regenerate")
    }

    // MARK: - generateTags: text-free scene must not re-arm

    private struct StubGen: MetadataGenerating {
        func makeMetadata(for signals: MetadataSignals) async -> CaptureMetadata {
            CaptureMetadata(generatedTitle: "unused", userTitle: nil, tags: [],
                            smartKeywords: ["unused"],
                            category: .other, confidence: 1, generatorVersion: 2)
        }
    }

    /// The scene exemption's safety argument was "the re-read writes real
    /// text, so the loop can't recur." A scene of photo/media windows OCRs to
    /// nothing every time, so that argument fails unless the terminal marker
    /// write itself becomes a no-op on the second pass. This proves the
    /// narrower invariant behind the fix: once a text-free scene already
    /// carries the `""` marker, re-running `generateTags` over it writes
    /// nothing new — the exemption still lets it re-OCR (that's the healing
    /// behavior for scenes that DO have text), but a repeat empty result must
    /// not persist again and must not announce a change.
    func test_generateTags_textFreeScene_secondPassWritesNothing() async throws {
        let layer = SceneLayer(assetID: "win", app: "Photos", title: "IMG_0001",
                               bundleID: "com.apple.Photos", originalFrame: .zero, z: 0)
        let windowPNG = png(image(gray: 0.5))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneOCR-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: image(gray: 1.0), composite: image(gray: 1.0),
                             annotations: [], crop: nil,
                             assets: ["win": windowPNG], captureKind: .liveCapture,
                             sceneLayers: [layer],
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        // OCR always finds nothing — a photo viewer / media player window.
        let coordinator = MetadataCoordinator(ocr: { _ in [] },
                                              metadataGenerator: { StubGen() })

        // Pass 1: needsTagBackfill fires (no keywords yet), OCR of the window
        // finds nothing, and the terminal "" marker is written for the first
        // time — a genuine change, so it DOES post.
        let firstChange = expectation(forNotification: .captureMetadataDidChange, object: nil)
        await coordinator.generateTags(for: url, packageKey: nil)
        await fulfillment(of: [firstChange], timeout: 2)
        let afterFirst = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(afterFirst.ocrText, "",
                       "text-free scene still gets the terminal marker after its first pass")
        XCTAssertTrue(afterFirst.metadata?.smartKeywords.isEmpty ?? true,
                      "no text means the generator is never reached")

        // Pass 2: the scene exemption still lets needsTagBackfill fire (it
        // ignores the "" marker for scenes), so generateTags runs again and
        // re-OCRs the window — but the result is unchanged, so this must be a
        // pure no-op: no re-write, no re-announcement. This is the fix: without
        // comparing against what's already stored, `wrote` was set unconditionally
        // and this second pass re-armed the editor's backfill check forever.
        let secondChange = expectation(forNotification: .captureMetadataDidChange, object: nil)
        secondChange.isInverted = true
        await coordinator.generateTags(for: url, packageKey: nil)
        await fulfillment(of: [secondChange], timeout: 0.3)
        let afterSecond = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(afterSecond.ocrText, "", "marker unchanged")
    }

    // MARK: - capture path (generate) end-to-end

    private struct FakeDescriber: SceneWindowDescribing {
        let answers: [String: String]
        func describe(windowText: String) async -> AIGenerationOutcome {
            guard let s = answers[windowText] else { return .skip }
            return .text(s)
        }
    }

    /// The capture path — not the backfill path — is what a freshly captured
    /// scene actually takes, and it summarizes INLINE. Before this test the
    /// per-window summary lived only in `generateSummary`, so a new scene got a
    /// generic 3-bullet blob instead, and because a stored summary is terminal
    /// it could never be corrected afterwards: scenes captured before the
    /// feature landed got the new format and scenes captured after it got the
    /// old one.
    ///
    /// Asserts both binding rules at once: the wallpaper is never handed to OCR,
    /// and the stored summary carries exactly one bullet per captured window.
    func test_generate_liveCapture_storesOneBulletPerWindow_andNeverOCRsWallpaper() async throws {
        let layers = [
            SceneLayer(assetID: "back", app: "Terminal", title: "zsh",
                       bundleID: "com.apple.Terminal", originalFrame: .zero, z: 1),
            SceneLayer(assetID: "front", app: "Safari", title: "Start",
                       bundleID: "com.apple.Safari", originalFrame: .zero, z: 0),
        ]
        let wallpaper = image(gray: 1.0)      // desktop icons + menu bar live here
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneCapture-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: wallpaper, composite: wallpaper,
                             annotations: [], crop: nil,
                             assets: ["front": png(image(gray: 0.25)),
                                      "back": png(image(gray: 0.75))],
                             captureKind: .liveCapture, sceneLayers: layers,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        let coordinator = MetadataCoordinator(
            ocr: { cgImage in
                let sample = Self.grayValue(of: cgImage)
                if sample > 0.9 {
                    XCTFail("the capture path must never OCR a scene's wallpaper")
                    return []
                }
                return sample < 0.5
                    ? [OCRLine(text: "Hello world", box: .zero)]
                    : [OCRLine(text: "make test", box: .zero)]
            },
            visualTags: { _ in VisualTags(structural: [], scene: []) },
            metadataGenerator: { StubGen() },
            sceneWindowDescriber: FakeDescriber(answers: [
                "Hello world": "a news article about SwiftUI.",
                "make test": "a test run with failures.",
            ]),
            summaryGatingOverride: true)

        // The summary is queued (not awaited) by `generate`; wait for the
        // pipeline's own completion signal rather than sleeping.
        let done = expectation(forNotification: .captureSummaryGenerationFinished, object: nil)
        // `source:` is supplied deliberately — for a scene it is the wallpaper
        // and the fast path that would OCR it must be bypassed.
        await coordinator.generate(for: url, sourceApp: nil, windowTitle: nil,
                                   captureKind: .liveCapture,
                                   captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                                   packageKey: nil, source: wallpaper)
        await fulfillment(of: [done], timeout: 5)

        let manifest = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(manifest.metadata?.summary, """
        - Safari — Start: a news article about SwiftUI.
        - Terminal — zsh: a test run with failures.
        """)
    }
}
