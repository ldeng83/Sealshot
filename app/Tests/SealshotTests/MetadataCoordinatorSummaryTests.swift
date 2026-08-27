import XCTest
import AppKit
import CryptoKit
@testable import Sealshot

@MainActor
final class MetadataCoordinatorSummaryTests: XCTestCase {

    private func img() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func tempSeal() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCS-\(UUID().uuidString).seal")
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        // Seed metadata + OCR so the summary phase has text and a row to patch.
        let meta = CaptureMetadata(generatedTitle: "T", userTitle: nil, tags: [],
                                   category: .other, confidence: 0, generatorVersion: 2)
        try SealMetadataStore.apply(metadata: meta, sourceApp: nil,
                                    ocrText: "Payment failed. Card declined.", to: url)
        return url
    }

    /// Always-on stub so gating doesn't depend on FM availability of the host.
    private struct StubSummary: SummaryGenerating {
        let outcome: AIGenerationOutcome
        func summarize(ocrText: String) async -> AIGenerationOutcome { outcome }
    }

    func test_generateSummary_writesSummaryAndPostsStartedThenFinished() async throws {
        let url = try tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = MetadataCoordinator(summaryGenerator: StubSummary(outcome: .text("It failed.")),
                                              summaryGatingOverride: true)

        let started = expectation(forNotification: .captureSummaryGenerationStarted, object: nil)
        let finished = expectation(forNotification: .captureSummaryGenerationFinished, object: nil)

        await coordinator.generateSummary(for: url, packageKey: nil)

        await fulfillment(of: [started, finished], timeout: 2)
        let manifest = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(manifest.metadata?.summary, "It failed.")
    }

    func test_generateSummary_skipWritesEmptyTerminalMarker() async throws {
        // .skip → persist "" so the panel shows "No summary" and never retries.
        let url = try tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = MetadataCoordinator(summaryGenerator: StubSummary(outcome: .skip),
                                              summaryGatingOverride: true)
        await coordinator.generateSummary(for: url, packageKey: nil)
        let manifest = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(manifest.metadata?.summary, "")
    }

    func test_generateSummary_transientWritesNothing() async throws {
        // .transient → leave the summary nil so it retries on a later pass.
        let url = try tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = MetadataCoordinator(summaryGenerator: StubSummary(outcome: .transient),
                                              summaryGatingOverride: true)
        await coordinator.generateSummary(for: url, packageKey: nil)
        let manifest = try SealMetadataStore.readManifest(at: url)
        XCTAssertNil(manifest.metadata?.summary)
    }

    func test_generateSummary_postsFinishedEvenWhenSkipped() async throws {
        let url = try tempSeal(); defer { try? FileManager.default.removeItem(at: url) }
        // Gating off → no write, but Finished must still fire so the UI flag clears.
        let coordinator = MetadataCoordinator(summaryGenerator: StubSummary(outcome: .text("ignored")),
                                              summaryGatingOverride: false)
        let finished = expectation(forNotification: .captureSummaryGenerationFinished, object: nil)
        await coordinator.generateSummary(for: url, packageKey: nil)
        await fulfillment(of: [finished], timeout: 2)
        let manifest = try SealMetadataStore.readManifest(at: url)
        XCTAssertNil(manifest.metadata?.summary)
    }

    // MARK: - Live Capture scenes

    private func png(gray: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png,
                                                                          properties: [:])!
    }

    /// A two-window scene package, seeded with metadata + OCR text so the
    /// summary phase runs. `back` is z:1, `front` is z:0.
    private func tempScene() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCSScene-\(UUID().uuidString).seal")
        let layers = [
            SceneLayer(assetID: "back", app: "Terminal", title: "zsh",
                       bundleID: "com.apple.Terminal", originalFrame: .zero, z: 1),
            SceneLayer(assetID: "front", app: "Safari", title: "Start",
                       bundleID: "com.apple.Safari", originalFrame: .zero, z: 0),
        ]
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             assets: ["front": png(gray: 0.25), "back": png(gray: 0.75)],
                             captureKind: .liveCapture, sceneLayers: layers,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let meta = CaptureMetadata(generatedTitle: "T", userTitle: nil, tags: [],
                                   category: .other, confidence: 0, generatorVersion: 2)
        try SealMetadataStore.apply(metadata: meta, sourceApp: nil,
                                    ocrText: "Safari — Start\nHello world", to: url)
        return url
    }

    private struct StubDescriber: SceneWindowDescribing {
        let outcome: AIGenerationOutcome
        func describe(windowText: String) async -> AIGenerationOutcome { outcome }
    }

    /// The scene branch stores one bullet per captured window, frontmost first,
    /// instead of the ordinary single-blob summary.
    func test_generateSummary_scene_writesOneBulletPerWindow() async throws {
        let url = try tempScene(); defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = MetadataCoordinator(
            ocr: { _ in [OCRLine(text: "some readable window text", box: .zero)] },
            summaryGenerator: StubSummary(outcome: .text("must not be used")),
            sceneWindowDescriber: StubDescriber(outcome: .text("a page of notes.")),
            summaryGatingOverride: true)

        await coordinator.generateSummary(for: url, packageKey: nil)

        let manifest = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(manifest.metadata?.summary, """
        - Safari — Start: a page of notes.
        - Terminal — zsh: a page of notes.
        """)
    }

    /// Deliberately unlike the non-scene path: when every description fails,
    /// the scene still stores name-only bullets (a list of what was captured)
    /// rather than the empty "No summary" terminal marker.
    func test_generateSummary_scene_allDescriptionsFail_storesNameOnlyBullets() async throws {
        let url = try tempScene(); defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = MetadataCoordinator(
            ocr: { _ in [OCRLine(text: "some readable window text", box: .zero)] },
            summaryGenerator: StubSummary(outcome: .text("must not be used")),
            sceneWindowDescriber: StubDescriber(outcome: .transient),
            summaryGatingOverride: true)

        await coordinator.generateSummary(for: url, packageKey: nil)

        let manifest = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(manifest.metadata?.summary, """
        - Safari — Start
        - Terminal — zsh
        """)
    }

    /// The scene branch returns early on its own path — the Finished
    /// notification must still fire so the Info panel's progress flag clears.
    func test_generateSummary_scene_postsFinished() async throws {
        let url = try tempScene(); defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = MetadataCoordinator(
            ocr: { _ in [] },
            sceneWindowDescriber: StubDescriber(outcome: .skip),
            summaryGatingOverride: true)
        let finished = expectation(forNotification: .captureSummaryGenerationFinished, object: nil)
        await coordinator.generateSummary(for: url, packageKey: nil)
        await fulfillment(of: [finished], timeout: 2)
    }

    // MARK: - Textless scene, REAL gating (no summaryGatingOverride)

    /// Every other scene test above forces gating with `summaryGatingOverride`,
    /// which would also mask `SummaryGating.shouldGenerate` rejecting the
    /// scene outright — the actual bug this fix addresses. This test drives
    /// the real gate (`AIFeaturePreference`/`AIAvailability` forced on, no
    /// override) through `ensureSummary` — the entry point the capture path
    /// calls for a scene — to prove a desktop of textless windows still gets
    /// its name-only bullet list end to end.
    func test_ensureSummary_textlessScene_realGating_storesNameOnlyBullets() async throws {
        let priorAI = AIFeaturePreference().enabled
        AIFeaturePreference().enabled = true
        AIAvailability.statusOverride = .available
        addTeardownBlock {
            AIFeaturePreference().enabled = priorAI
            AIAvailability.statusOverride = nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCSSceneTextless-\(UUID().uuidString).seal")
        defer { try? FileManager.default.removeItem(at: url) }
        let layers = [
            SceneLayer(assetID: "back", app: "Terminal", title: "zsh",
                       bundleID: "com.apple.Terminal", originalFrame: .zero, z: 1),
            SceneLayer(assetID: "front", app: "Safari", title: "Start",
                       bundleID: "com.apple.Safari", originalFrame: .zero, z: 0),
        ]
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             assets: ["front": png(gray: 0.25), "back": png(gray: 0.75)],
                             captureKind: .liveCapture, sceneLayers: layers,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        let meta = CaptureMetadata(generatedTitle: "T", userTitle: nil, tags: [],
                                   category: .other, confidence: 0, generatorVersion: 2)
        // The terminal marker a textless scene's OCR pass actually persists.
        try SealMetadataStore.apply(metadata: meta, sourceApp: nil, ocrText: "", to: url)

        let coordinator = MetadataCoordinator(
            ocr: { _ in [] },   // every window textless — photo/video windows
            sceneWindowDescriber: StubDescriber(outcome: .skip))

        coordinator.ensureSummary(for: url, packageKey: nil)
        let finished = expectation(forNotification: .captureSummaryGenerationFinished, object: nil)
        await fulfillment(of: [finished], timeout: 5)

        let manifest = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(manifest.metadata?.summary, """
        - Safari — Start
        - Terminal — zsh
        """)
    }
}
