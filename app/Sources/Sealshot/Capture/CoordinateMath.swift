import CoreGraphics

/// Pure-function coordinate helpers shared between the capture overlay
/// (AppKit, bottom-left origin) and ScreenCaptureKit (top-left origin,
/// pixel-sized output).
enum CoordinateMath {
    /// Translate a global AppKit rect into the display's local AppKit
    /// coordinate space (still bottom-left origin, in points).
    static func displayLocalRect(global: CGRect, screenOrigin: CGPoint) -> CGRect {
        CGRect(
            x: global.origin.x - screenOrigin.x,
            y: global.origin.y - screenOrigin.y,
            width: global.width,
            height: global.height
        )
    }

    /// Flip Y on a display-local rect from AppKit (bottom-left origin)
    /// to top-left origin, suitable for `SCStreamConfiguration.sourceRect`.
    static func flipY(localBottomLeft: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(
            x: localBottomLeft.origin.x,
            y: screenHeight - (localBottomLeft.origin.y + localBottomLeft.height),
            width: localBottomLeft.width,
            height: localBottomLeft.height
        )
    }

    /// Intersect `rect` with `bounds` so a selection cannot extend past the
    /// screen it started on. Returns `CGRect.null` if they don't overlap
    /// (unreachable in practice — a drag always starts inside its screen).
    static func clampToBounds(_ rect: CGRect, bounds: CGRect) -> CGRect {
        rect.intersection(bounds)
    }

    /// Snap a point rect to the device pixel grid for the given backing
    /// `scale`. After snapping, `origin * scale` and `size * scale` are
    /// integers, so `SCStreamConfiguration.sourceRect` lands on whole pixels.
    ///
    /// This matters because ScreenCaptureKit *resamples* (bilinearly blurs) the
    /// entire capture when `sourceRect` has fractional coordinates — and a
    /// mouse-drag selection almost always produces fractional points. macOS's
    /// own `screencapture` snaps the same way, which is why its output stays
    /// crisp where an unrounded `sourceRect` looks soft.
    static func snapToPixelGrid(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        return CGRect(
            x: (rect.origin.x * scale).rounded() / scale,
            y: (rect.origin.y * scale).rounded() / scale,
            width: (rect.size.width * scale).rounded() / scale,
            height: (rect.size.height * scale).rounded() / scale
        )
    }

    /// Convert a point-sized region to integer pixel dimensions at the
    /// given backing scale, never below 1×1. Used for
    /// `SCStreamConfiguration.width/height`.
    static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (
            max(1, Int((points.width * scale).rounded())),
            max(1, Int((points.height * scale).rounded()))
        )
    }

    /// Inverse of `pixelSize`: pixel W×H → logical points at `scale`. A
    /// non-positive scale is treated as 1 (defensive; matches `pixelSize`).
    static func pointSize(pixels: (width: Int, height: Int), scale: CGFloat) -> CGSize {
        let s = scale > 0 ? scale : 1
        return CGSize(width: CGFloat(pixels.width) / s, height: CGFloat(pixels.height) / s)
    }
}
