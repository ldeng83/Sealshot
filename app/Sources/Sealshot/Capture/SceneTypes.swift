import CoreGraphics
import Foundation

/// One captured window, ready to be composited into a Live Capture scene.
struct CapturedWindow: Equatable {
    let image: CGImage
    let globalFrame: CGRect
    let z: Int
    let app: String
    let bundleID: String
    let title: String
}

/// One captured display's wallpaper/background, used as scene backdrop.
struct CapturedDisplay: Equatable {
    let wallpaper: CGImage
    let globalFrame: CGRect
}

/// Raw output of a Live Capture pass: every window + display captured, plus
/// the scale factor used to convert global points to source pixels.
struct SceneCaptureResult: Equatable {
    let windows: [CapturedWindow]     // z 0..N, front-to-back
    let displays: [CapturedDisplay]
    let scale: CGFloat
    let skippedCount: Int
}

/// A layered editor scene composed from a `SceneCaptureResult` — ready to
/// seed a new capture (backdrop image + `.image` annotations for windows).
struct ComposedScene {
    let backdrop: CGImage
    let layers: [Annotation]          // .image, back-to-front (last = topmost)
    let assets: [String: Data]        // assetID -> PNG bytes
    let sceneLayers: [SceneLayer]
    let originalFrames: [String: CGRect]  // assetID -> original rect (source-pixel)
    let sourceSize: CGSize             // backdrop pixel size
}
