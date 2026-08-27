import AppKit
import CoreGraphics
import ImageIO

/// `decodeCGImageFromPNG(_:)` already exists in `SealPackageIO.swift` and
/// `AnnotatedPNGIO.swift`, but both are `private` to their file. Rather than
/// widen their access (which would touch existing files beyond this
/// additive feature), this is a small local equivalent.
private func decodeCGImageFromPNG(_ data: Data) -> CGImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// Writes a composed Live Capture scene (`ComposedScene`) to a `.seal`
/// package and builds the `EditorState` used to open it. Bridges
/// `SceneComposer`'s pure output into the existing `.seal` I/O and editor
/// document model — no new persistence format.
enum LiveCaptureWriter {
    static func destination(in saveFolder: URL, now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH_mm_ss_SSS"
        return saveFolder.appendingPathComponent("Live Capture \(f.string(from: now)).seal")
    }

    static func write(_ scene: ComposedScene, to url: URL,
                      crypto: SealPackageCryptoContext) throws {
        let decoded = scene.assets.compactMapValues { decodeCGImageFromPNG($0) }
        let compositeNS = render(image: scene.backdrop, annotations: scene.layers,
                                 crop: nil, assets: decoded)
        guard let composite = nsImageToCGImage(compositeNS) else {
            throw SceneComposerError.backdropFailed
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        SceneDiag.note("CAPTURE-WRITE \(SceneDiag.name(url)): layers=\(scene.layers.count) "
            + "sceneLayers=\(scene.sceneLayers.count) assets=\(scene.assets.count)")
        try writeSealPackage(
            to: url, source: scene.backdrop, composite: composite,
            annotations: scene.layers, crop: nil,
            assets: scene.assets, captureKind: .liveCapture,
            sceneLayers: scene.sceneLayers, crypto: crypto)
    }

    @MainActor
    static func makeState(_ scene: ComposedScene, url: URL) -> EditorState {
        let state = EditorState(sourceImage: scene.backdrop, sourceURL: url)
        for (id, data) in scene.assets { state.registerImageAsset(id: id, data: data) }
        state.annotations = scene.layers
        state.sceneOriginalFrames = scene.originalFrames   // Task 4
        SceneDiag.note("PRESENT-FRESH \(SceneDiag.name(url)): layers=\(scene.layers.count) "
            + "frames=\(scene.originalFrames.count) assets=\(scene.assets.count)")
        return state
    }
}
