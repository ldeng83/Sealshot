import CoreGraphics

/// Pure geometry for cropping a selection out of a frozen display image.
///
/// "View-local" rects are in the overlay view's coordinates: AppKit-style
/// bottom-left origin, points, spanning exactly one display. The frozen image
/// is that display's pixels, top-left origin. The same math serves region
/// selections (already view-local) and window frames (converted via
/// `windowViewLocalRect`, the same mapping the overlay uses to highlight).
enum FrozenFrameCrop {

    /// Map a view-local points rect to an integral pixel rect in the frozen
    /// image: y-flip, scale by the image/view ratio, round, clamp.
    static func pixelRect(viewLocal: CGRect, viewSize: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let sx = CGFloat(imageWidth) / viewSize.width
        let sy = CGFloat(imageHeight) / viewSize.height
        let x = (viewLocal.minX * sx).rounded()
        let y = ((viewSize.height - viewLocal.maxY) * sy).rounded()
        let w = (viewLocal.width * sx).rounded()
        let h = (viewLocal.height * sy).rounded()
        let raw = CGRect(x: x, y: y, width: w, height: h)
        return raw.intersection(CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight)))
    }

    /// Inverse of `pixelRect`: an image pixel rect (top-left origin) → the
    /// view-local points rect it covers. Used to place detected boundary rects
    /// on the overlay.
    static func viewLocalRect(pixelRect: CGRect, viewSize: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let sx = viewSize.width / CGFloat(imageWidth)
        let sy = viewSize.height / CGFloat(imageHeight)
        return CGRect(
            x: pixelRect.minX * sx,
            y: viewSize.height - (pixelRect.maxY * sy),
            width: pixelRect.width * sx,
            height: pixelRect.height * sy
        )
    }

    /// An `SCWindow.frame` (global, top-left origin) → view-local rect on the
    /// panel covering `screenFrame` (global AppKit frame). Mirrors the overlay
    /// view's highlight mapping so the crop matches what was highlighted.
    ///
    /// `primaryMaxY` is the flip line between the two global coordinate
    /// systems: CG y-down coordinates originate at the TOP of the PRIMARY
    /// display, i.e. at AppKit y == primary.frame.maxY. (Flipping around the
    /// local screen's own height was only coincidentally correct for the
    /// primary and same-height side-by-side monitors — on a vertically offset
    /// or different-height display every rect landed wrong.)
    static func windowViewLocalRect(
        windowFrame: CGRect, screenFrame: CGRect, primaryMaxY: CGFloat
    ) -> CGRect {
        let appKitBottomY = primaryMaxY - windowFrame.origin.y - windowFrame.height
        return CGRect(
            x: windowFrame.origin.x - screenFrame.origin.x,
            y: appKitBottomY - screenFrame.origin.y,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }

    /// Crop `viewLocal` out of the frozen `image`. Nil for empty/degenerate rects.
    static func crop(_ image: CGImage, viewLocal: CGRect, viewSize: CGSize) -> CGImage? {
        let px = pixelRect(viewLocal: viewLocal, viewSize: viewSize,
                           imageWidth: image.width, imageHeight: image.height)
        guard px.width >= 1, px.height >= 1 else { return nil }
        return image.cropping(to: px)
    }
}
