import CoreGraphics
import Foundation

/// Translate the focus `start` (image-space, top-left origin) by the OPPOSITE of
/// an image-space drag, so the image content follows the hand while the focus
/// frame stays fixed on screen. Clamped so the focus never leaves `bounds`
/// (the image) — this is the "image stops at the edge" limit. Pure.
func pannedFocus(start: CGRect, dragDeltaImage: CGPoint, within bounds: CGRect) -> CGRect {
    var r = start.offsetBy(dx: -dragDeltaImage.x, dy: -dragDeltaImage.y)
    if r.minX < bounds.minX { r.origin.x = bounds.minX }
    if r.minY < bounds.minY { r.origin.y = bounds.minY }
    if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
    if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
    return r
}

/// Whether the pointer moved far enough to count as a drag (vs a click). Used to
/// tell a right-DRAG (pan) from a right-CLICK (context menu).
func panDragExceedsThreshold(_ from: CGPoint, _ to: CGPoint, threshold: CGFloat) -> Bool {
    hypot(to.x - from.x, to.y - from.y) > threshold
}
