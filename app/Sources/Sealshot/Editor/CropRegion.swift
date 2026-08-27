import AppKit
import CoreGraphics

/// Composite `image` + `annotations` and return the pixels inside `rect`
/// (visible-image space, top-left origin). When a destructive crop or enhanced
/// base is active, pass the real `crop`/`scale` so the extraction matches what
/// the canvas displays. Defaults to no-crop / scale-1 so existing callers
/// (tests, etc.) compile and behave identically. Returns nil if the rect is
/// empty or yields no pixels. Used by crop Copy / Cut / Soft Crop.
func compositedRegion(image: CGImage, annotations: [Annotation], assets: [String: Data],
                      rect: CGRect, crop: CGRect? = nil, scale: CGFloat = 1) -> CGImage? {
    let decoded = decodeAssets(assets)
    let composite = render(image: image, annotations: annotations,
                           crop: crop, scale: scale, focus: nil, assets: decoded)
    guard let cg = nsImageToCGImage(composite) else { return nil }
    // `rect` is in visible-image space; the composite is at `scale` pixels per
    // visible unit, so multiply to get pixel coordinates inside the composite.
    let pr = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                    width: rect.width * scale, height: rect.height * scale).integral
    guard pr.width >= 1, pr.height >= 1 else { return nil }
    return cg.cropping(to: pr)
}

/// Same as `compositedRegion`, PNG-encoded for the clipboard.
func compositedRegionPNG(image: CGImage, annotations: [Annotation], assets: [String: Data],
                         rect: CGRect, crop: CGRect? = nil, scale: CGFloat = 1) -> Data? {
    guard let region = compositedRegion(image: image, annotations: annotations,
                                        assets: assets, rect: rect,
                                        crop: crop, scale: scale) else { return nil }
    let rep = NSBitmapImageRep(cgImage: region)
    return rep.representation(using: .png, properties: [:])
}

/// The offset at which a soft-cropped object is placed relative to the selection
/// origin: nominal up-right (+x, −y), flipped per-axis when the offset would
/// push the object outside `imageBounds`, so it stays on-image and visibly
/// detached from the selection.
func softCropOffset(selection: CGRect, imageBounds: CGRect, nominal: CGFloat = 12) -> CGPoint {
    var dx = nominal
    var dy = -nominal
    if selection.maxX + dx > imageBounds.maxX { dx = -nominal }
    if selection.minY + dy < imageBounds.minY { dy = nominal }
    return CGPoint(x: dx, y: dy)
}

// MARK: - Internal helpers

/// Decode PNG/JPEG asset data to CGImages for the renderer.
private func decodeAssets(_ assets: [String: Data]) -> [String: CGImage] {
    var out: [String: CGImage] = [:]
    for (key, data) in assets {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        out[key] = img
    }
    return out
}
