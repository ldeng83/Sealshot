import CoreGraphics
import CryptoKit
import Foundation

/// Per-capture whole-image zoom memory: each image remembers its OWN last zoom
/// across image switches and relaunch, keyed by a hash of its file path — so
/// changing one image's zoom never bleeds into another. Unsaved captures (no
/// URL) are not remembered and fall back to fit-to-window. Focus-crop zooms are
/// stored like any other (saved screenshots commonly carry a focus rect).
///
/// Replaces the former single global `editorLastZoom` preference, which shared
/// one value across every capture. Stored as a compact `[pathHash: zoom]` map
/// in `UserDefaults` (zoom is innocuous and the path is hashed); zoom changes
/// are frequent during a slider drag, so a lightweight defaults write beats a
/// per-capture sealed file.
enum ImageZoomMemory {

    private static let key = "editorImageZoom"
    /// Cap the map so it can't grow without bound; zoom is non-critical, so an
    /// evicted entry just re-fits on next open.
    private static let maxEntries = 1000

    static func clamp(_ zoom: CGFloat) -> CGFloat {
        EditorCanvasScrollView.clampZoom(zoom)
    }

    /// Stable, filesystem-safe key that doesn't leak the path.
    private static func pathHash(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The remembered zoom for `url`, or nil (→ fall back to fit) when there's
    /// none yet or the capture is unsaved. Clamped on read so a stale value
    /// stays in range.
    static func load(for url: URL?, _ defaults: UserDefaults = .standard) -> CGFloat? {
        guard let url else { return nil }
        let map = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard let stored = map[pathHash(url)] else { return nil }
        return clamp(CGFloat(stored))
    }

    /// Remember `zoom` for `url`. No-op for unsaved captures (nil URL).
    static func store(_ zoom: CGFloat, for url: URL?, _ defaults: UserDefaults = .standard) {
        guard let url else { return }
        var map = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        map[pathHash(url)] = Double(clamp(zoom))
        if map.count > maxEntries {
            for k in map.keys.prefix(map.count - maxEntries) { map.removeValue(forKey: k) }
        }
        defaults.set(map, forKey: key)
    }
}
