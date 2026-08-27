import CoreGraphics

/// "Expand canvas to fit" as a VIEWPORT operation: the visible canvas is a
/// window (`croppedRect`) into the untouched `sourceImage`. Growing just
/// enlarges that window — possibly past the source edge, where it renders
/// transparent. The source image is never modified, so the original is always
/// recoverable (Revert to Original / clear the crop), and the size change is a
/// plain `croppedRect` edit that the normal undo already reverts.
enum CanvasExpander {
    /// Enlarge `current` (the viewport, in source coords) so `annotationBounds`
    /// (in VISIBLE coords, i.e. relative to `current`) fits inside it. Returns
    /// the new viewport and the shift applied to content when it grows on the
    /// left/top, or nil when everything already fits (within `epsilon`).
    static func expandedViewport(
        current: CGRect, annotationBounds box: CGRect, epsilon: CGFloat = 0.5
    ) -> (viewport: CGRect, shift: CGVector)? {
        let left = max(0, -box.minX)
        let top = max(0, -box.minY)
        let right = max(0, box.maxX - current.width)
        let bottom = max(0, box.maxY - current.height)
        guard left > epsilon || top > epsilon || right > epsilon || bottom > epsilon else {
            return nil
        }
        let l = left.rounded(.up), t = top.rounded(.up)
        let r = right.rounded(.up), b = bottom.rounded(.up)
        let viewport = CGRect(x: current.minX - l, y: current.minY - t,
                              width: current.width + l + r, height: current.height + t + b)
        return (viewport, CGVector(dx: l, dy: t))
    }

    /// The visible base pixels for the `crop` viewport (source coords) at
    /// `baseScale`. `contentClip` (source coords) is the region of the source
    /// actually shown — everything outside it (including cropped-away source
    /// pixels a grown viewport now overlaps, and area past the source edge) is
    /// TRANSPARENT. nil = show the whole source within the viewport. A plain
    /// in-bounds crop with no content clip takes the fast (copy-free) path.
    static func viewportBase(from base: CGImage, crop: CGRect,
                             contentClip: CGRect?, baseScale: CGFloat) -> CGImage {
        let px = CGRect(x: crop.minX * baseScale, y: crop.minY * baseScale,
                        width: crop.width * baseScale, height: crop.height * baseScale)
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        if contentClip == nil, bounds.contains(px), let cropped = base.cropping(to: px) {
            return cropped
        }
        let w = max(1, Int(px.width.rounded())), h = max(1, Int(px.height.rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        // Clip to the content region (transparent outside), so a grown viewport
        // never reveals the cropped-away source. CG is bottom-left origin.
        if let content = contentClip {
            let cx = (content.minX - crop.minX) * baseScale
            let cyTop = (content.minY - crop.minY) * baseScale
            ctx.clip(to: CGRect(x: cx, y: CGFloat(h) - cyTop - content.height * baseScale,
                                width: content.width * baseScale, height: content.height * baseScale))
        }
        // Place the source at −crop.origin (top-left) into the viewport.
        let x = -crop.minX * baseScale
        let by = CGFloat(h) + crop.minY * baseScale - CGFloat(base.height)
        ctx.draw(base, in: CGRect(x: x, y: by, width: CGFloat(base.width), height: CGFloat(base.height)))
        return ctx.makeImage() ?? base
    }
}
