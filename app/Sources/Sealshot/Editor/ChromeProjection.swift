import CoreGraphics

/// Pure image↔screen projection for editor selection chrome. It composes image
/// geometry with AppKit's complete canvas→overlay view transform:
///   1. image → canvas (document) space: imagePoint · scale + drawOrigin
///   2. canvas → overlay space:          canvasPoint · canvasToScreen
///
/// The second step deliberately remains a full affine transform. NSScrollView
/// can introduce a frame↔bounds scale in addition to its public magnification
/// when legacy scrollers reserve space. Reducing that transform to a scalar zoom
/// plus an origin makes chrome drift away from the pixels it marks.
struct ChromeProjection: Equatable {
    /// Base fit scale (image px → canvas points); ≈ EditorCanvasView.currentScale().
    let scale: CGFloat
    /// Canvas-space origin of the drawn image (imageDrawRect().origin).
    let drawOrigin: CGPoint
    /// The exact AppKit canvas→overlay transform, including scroll, centering,
    /// magnification, clip frame/bounds scaling, and viewport translation.
    let canvasToScreen: CGAffineTransform

    init(scale: CGFloat, drawOrigin: CGPoint, canvasToScreen: CGAffineTransform) {
        self.scale = scale
        self.drawOrigin = drawOrigin
        self.canvasToScreen = canvasToScreen
    }

    /// Convenience constructor for simple scalar projections and unit tests.
    /// Runtime overlay projection uses the affine initializer above.
    init(scale: CGFloat, drawOrigin: CGPoint, scrollOrigin: CGPoint,
         magnification: CGFloat, viewportOrigin: CGPoint = .zero) {
        self.init(
            scale: scale,
            drawOrigin: drawOrigin,
            canvasToScreen: CGAffineTransform(
                a: magnification, b: 0,
                c: 0, d: magnification,
                tx: viewportOrigin.x - scrollOrigin.x * magnification,
                ty: viewportOrigin.y - scrollOrigin.y * magnification
            )
        )
    }

    static let identity = ChromeProjection(scale: 1, drawOrigin: .zero,
                                           scrollOrigin: .zero, magnification: 1)

    func screen(fromImage p: CGPoint) -> CGPoint {
        let cx = p.x * scale + drawOrigin.x
        let cy = p.y * scale + drawOrigin.y
        return CGPoint(x: cx, y: cy).applying(canvasToScreen)
    }

    func image(fromScreen p: CGPoint) -> CGPoint {
        let canvas = p.applying(canvasToScreen.inverted())
        let cx = canvas.x
        let cy = canvas.y
        return CGPoint(x: (cx - drawOrigin.x) / scale,
                       y: (cy - drawOrigin.y) / scale)
    }

    func screen(fromImage r: CGRect) -> CGRect {
        let points = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY),
        ].map(screen(fromImage:))
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// Horizontal length in image units → length in screen points.
    func screenLength(_ imageLength: CGFloat) -> CGFloat {
        let a = screen(fromImage: CGPoint.zero)
        let b = screen(fromImage: CGPoint(x: imageLength, y: 0))
        return hypot(b.x - a.x, b.y - a.y)
    }
}
