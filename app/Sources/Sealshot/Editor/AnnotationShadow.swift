import AppKit
import CoreGraphics

/// CGContext shadow offset for a screen-space `offset`. The canvas is y-down
/// (`isFlipped`), so a screen "down" is +height; the export bitmap context is
/// y-up, so "down" is -height. `scale` maps 1×-space units to the target
/// context: the export context is already scaled, so callers pass 1 there and
/// the live canvas scale on the canvas path.
func cgShadowOffset(_ offset: CGSize, yDown: Bool, scale: CGFloat) -> CGSize {
    CGSize(width: offset.width * scale,
           height: (yDown ? offset.height : -offset.height) * scale)
}

/// Which geometries render a shadow. Blur (a redaction) and image overlays do not.
func geometryCastsShadow(_ geometry: Geometry) -> Bool {
    switch geometry {
    case .arrow, .rectangle, .text, .ellipse, .line, .badge, .pen, .penArrow: return true
    case .blur, .image, .cut: return false   // .cut is a transparent hole — no shadow
    }
}

/// Set (or clear) the CGContext drop shadow for an upcoming shape draw. Call
/// inside a saved gState and draw the shape, then restore. No-op clear when the
/// shadow is disabled. The shadow color carries `shadow.opacity` as its alpha.
func applyShadow(_ shadow: ShadowStyle, to ctx: CGContext?, yDown: Bool, scale: CGFloat) {
    guard let ctx else { return }
    guard shadow.enabled else { ctx.setShadow(offset: .zero, blur: 0, color: nil); return }
    let color = shadow.color.nsColor.usingColorSpace(.sRGB)?
        .withAlphaComponent(CGFloat(shadow.opacity)) ?? NSColor(white: 0, alpha: CGFloat(shadow.opacity))
    ctx.setShadow(offset: cgShadowOffset(shadow.offset, yDown: yDown, scale: scale),
                  blur: shadow.blur * scale, color: color.cgColor)
}

/// Map a point inside a square position pad (side `size`, y-down/flipped) to a
/// shadow offset in ±`maxOffset`. Center → (0,0); right/bottom edges → +max; clamped.
func shadowPadOffset(point: CGPoint, size: CGFloat, maxOffset: CGFloat) -> CGSize {
    let half = size / 2
    func axis(_ v: CGFloat) -> CGFloat {
        let n = max(-1, min(1, (v - half) / half))
        return (n * maxOffset).rounded()
    }
    return CGSize(width: axis(point.x), height: axis(point.y))
}

/// Snap to one of 8 directions (`dx`,`dy` ∈ {-1,0,1}) at the current offset's
/// distance (or `fallbackDistance` when currently centered). (0,0) → no offset.
func shadowDirectionSnap(current: CGSize, dx: Int, dy: Int, fallbackDistance: CGFloat) -> CGSize {
    if dx == 0 && dy == 0 { return .zero }
    let currentDist = hypot(current.width, current.height)
    let dist = currentDist == 0 ? fallbackDistance : currentDist
    let m = Double(dx * dx + dy * dy).squareRoot()
    return CGSize(width: (CGFloat(Double(dx) / m) * dist).rounded(),
                  height: (CGFloat(Double(dy) / m) * dist).rounded())
}
