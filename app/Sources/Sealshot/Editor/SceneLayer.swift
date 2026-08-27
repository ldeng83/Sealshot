import Foundation

/// Per-window metadata for a Live Capture scene, persisted in the manifest.
/// `originalFrame` is the window layer's rect in base-image (source.png) pixel
/// space at capture time — used by "Restore Original Layout".
struct SceneLayer: Codable, Equatable {
    let assetID: String
    let app: String
    let title: String
    let bundleID: String
    let originalFrame: CGRect
    let z: Int
}

extension SceneLayer {
    /// `EditorState.sceneOriginalFrames` rebuilt from persisted layers — the
    /// hydration a reopened Live Capture needs so it keeps its scene identity
    /// (scene menu items + layout-aware Revert) across app restarts.
    static func originalFrames(from layers: [SceneLayer]?) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: (layers ?? []).map { ($0.assetID, $0.originalFrame) })
    }
}
