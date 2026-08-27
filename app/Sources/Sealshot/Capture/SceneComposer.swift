import AppKit
import CoreGraphics

enum SceneComposerError: Error { case noWindows, backdropFailed }

/// Pure, testable math: turns a `SceneCaptureResult` (captured windows +
/// display wallpapers) into a `ComposedScene` — a backdrop image plus
/// `.image` annotation layers positioned in source-pixel space. No
/// ScreenCaptureKit or UI dependencies live here.
enum SceneComposer {
    static func compose(_ result: SceneCaptureResult) throws -> ComposedScene {
        guard !result.windows.isEmpty else { throw SceneComposerError.noWindows }
        let s = result.scale

        // Union of all window + display frames (global, top-left).
        let frames = result.windows.map(\.globalFrame) + result.displays.map(\.globalFrame)
        let minX = frames.map(\.minX).min()!, minY = frames.map(\.minY).min()!
        let maxX = frames.map(\.maxX).max()!, maxY = frames.map(\.maxY).max()!
        let origin = CGPoint(x: minX, y: minY)
        let wPx = max(1, Int(((maxX - minX) * s).rounded()))
        let hPx = max(1, Int(((maxY - minY) * s).rounded()))

        // Backdrop: wallpapers composited at their offsets (bottom-left context → flip y).
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: wPx, height: hPx, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SceneComposerError.backdropFailed }
        for d in result.displays {
            let x = (d.globalFrame.minX - origin.x) * s
            let topPx = (d.globalFrame.minY - origin.y) * s
            let dw = CGFloat(d.wallpaper.width), dh = CGFloat(d.wallpaper.height)
            ctx.draw(d.wallpaper, in: CGRect(x: x, y: CGFloat(hPx) - topPx - dh, width: dw, height: dh))
        }
        guard let backdrop = ctx.makeImage() else { throw SceneComposerError.backdropFailed }

        // Window layers: back-to-front (reverse z), rect in source-pixel top-left space.
        var layers: [Annotation] = []
        var assets: [String: Data] = [:]
        var sceneLayers: [SceneLayer] = []
        var originals: [String: CGRect] = [:]
        for w in result.windows.sorted(by: { $0.z > $1.z }) {   // high z first = back
            guard let png = try? CaptureOutputWriter.encodePNG(w.image) else { continue }
            let assetID = UUID().uuidString
            let rect = CGRect(
                x: (w.globalFrame.minX - origin.x) * s,
                y: (w.globalFrame.minY - origin.y) * s,
                width: CGFloat(w.image.width), height: CGFloat(w.image.height))
            assets[assetID] = png
            originals[assetID] = rect
            layers.append(Annotation(
                geometry: .image(rect: rect, assetID: assetID),
                style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0, opacity: 1.0)))
            sceneLayers.append(SceneLayer(
                assetID: assetID, app: w.app, title: w.title, bundleID: w.bundleID,
                originalFrame: rect, z: w.z))
        }
        guard !layers.isEmpty else { throw SceneComposerError.noWindows }
        return ComposedScene(
            backdrop: backdrop, layers: layers, assets: assets,
            sceneLayers: sceneLayers, originalFrames: originals,
            sourceSize: CGSize(width: wPx, height: hPx))
    }
}
