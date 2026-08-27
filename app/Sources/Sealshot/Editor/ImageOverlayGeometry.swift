import CoreGraphics

/// Placement, sizing and resize math for image overlay annotations.
/// Pure functions — see ImageOverlayGeometryTests.

/// Where an inserted overlay lands: natural size, downscaled (aspect kept)
/// so its larger side is at most half the canvas's smaller dimension;
/// centered at `point` (drop location / cursor) or the canvas center,
/// then clamped fully inside the canvas.
func overlayInsertRect(imageSize: CGSize, canvas: CGSize, at point: CGPoint?) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
          canvas.width > 0, canvas.height > 0 else { return .zero }
    let cap = min(canvas.width, canvas.height) * 0.5
    let scale = min(1, cap / max(imageSize.width, imageSize.height))
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let center = point ?? CGPoint(x: canvas.width / 2, y: canvas.height / 2)
    var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
    origin.x = min(max(0, origin.x), max(0, canvas.width - size.width))
    origin.y = min(max(0, origin.y), max(0, canvas.height - size.height))
    return CGRect(origin: origin, size: size)
}

/// Stored-asset size cap: never keep more pixels than the canvas itself
/// (a 50 MP photo must not bloat every save). Aspect preserved.
func overlayAssetTargetSize(imageSize: CGSize, canvasPixels: CGSize) -> CGSize {
    guard imageSize.width > canvasPixels.width || imageSize.height > canvasPixels.height
    else { return imageSize }
    let scale = min(canvasPixels.width / imageSize.width,
                    canvasPixels.height / imageSize.height)
    return CGSize(width: (imageSize.width * scale).rounded(),
                  height: (imageSize.height * scale).rounded())
}

/// Corner-handle resize with the aspect ratio locked (width/height = aspect).
/// The dragged corner follows the pointer's dominant axis; the opposite
/// corner stays anchored. Non-corner handles return the rect unchanged.
/// Canvas clamping is the caller's responsibility — the result may extend
/// outside the image (negative origin included), like every other resize.
func aspectLockedRect(from rect: CGRect, handle: AnnotationHandle,
                      to point: CGPoint, aspect: CGFloat,
                      minSide: CGFloat = 16) -> CGRect {
    guard aspect > 0 else { return rect }
    let anchor: CGPoint
    switch handle {
    case .topLeft:     anchor = CGPoint(x: rect.maxX, y: rect.maxY)
    case .topRight:    anchor = CGPoint(x: rect.minX, y: rect.maxY)
    case .bottomLeft:  anchor = CGPoint(x: rect.maxX, y: rect.minY)
    case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY)
    default: return rect
    }
    let dx = abs(point.x - anchor.x), dy = abs(point.y - anchor.y)
    // Dominant axis wins; the other follows the locked ratio.
    var width = max(dx, dy * aspect)
    var height = width / aspect
    let minW = max(minSide, minSide * aspect), minH = minW / aspect
    width = max(width, minW); height = max(height, minH)
    let x = point.x >= anchor.x ? anchor.x : anchor.x - width
    let y = point.y >= anchor.y ? anchor.y : anchor.y - height
    return CGRect(x: x, y: y, width: width, height: height)
}

/// Rect for a replacement image: keep the current rect's center, adopt the
/// new image's aspect, sized to fit inside the current rect's larger
/// dimension.
func replacementFitRect(current: CGRect, newImageSize: CGSize) -> CGRect {
    guard newImageSize.width > 0, newImageSize.height > 0,
          current.width > 0, current.height > 0 else { return current }
    let bound = max(current.width, current.height)
    let scale = min(bound / newImageSize.width, bound / newImageSize.height)
    let size = CGSize(width: newImageSize.width * scale, height: newImageSize.height * scale)
    return CGRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2,
                  width: size.width, height: size.height)
}
