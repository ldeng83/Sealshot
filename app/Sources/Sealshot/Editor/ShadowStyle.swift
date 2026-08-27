import AppKit
import CoreGraphics

/// A drop-shadow effect for an annotation. `offset` is in SCREEN space (image
/// pixels): positive `height` casts the shadow downward. `opacity` is the
/// shadow's own alpha (0…1), independent of the object's `Style.opacity`.
/// Shared shape for both the per-object `Style.shadow` field and the per-tool
/// remembered default in `ToolShadowDefaults`.
struct ShadowStyle: Equatable, Codable {
    var enabled: Bool
    var color: SerializableColor
    var blur: CGFloat
    var offset: CGSize
    var opacity: Double

    /// New-object default: a pronounced black drop shadow, ON.
    static let pronounced = ShadowStyle(
        enabled: true, color: SerializableColor(.black),
        blur: 14, offset: CGSize(width: 4, height: 4), opacity: 0.55)

    /// Codable/legacy default: same look but DISABLED, so existing saved
    /// annotations (no shadow key) render exactly as before.
    static let off = ShadowStyle(
        enabled: false, color: SerializableColor(.black),
        blur: 14, offset: CGSize(width: 4, height: 4), opacity: 0.55)
}
