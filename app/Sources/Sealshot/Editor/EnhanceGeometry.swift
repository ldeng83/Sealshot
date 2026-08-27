import CoreGraphics

/// Pure geometry for tiled super-resolution. The model takes a fixed
/// `tile`×`tile` RGB image and returns `tile*upscale` square; we tile the
/// source with no overlap, run each tile, and stitch.
enum EnhanceGeometry {
    /// Source-image tile rects (each ≤ `tile`×`tile`) covering the whole image
    /// at `tile` stride, top-left origin, no overlap.
    static func tiles(imageWidth: Int, imageHeight: Int, tile: Int) -> [CGRect] {
        guard imageWidth > 0, imageHeight > 0, tile > 0 else { return [] }
        var rects: [CGRect] = []
        var y = 0
        while y < imageHeight {
            let h = min(tile, imageHeight - y)
            var x = 0
            while x < imageWidth {
                let w = min(tile, imageWidth - x)
                rects.append(CGRect(x: x, y: y, width: w, height: h))
                x += tile
            }
            y += tile
        }
        return rects
    }

    /// Final output pixel size for an `outputScale`× enhancement.
    static func outputSize(imageWidth: Int, imageHeight: Int, outputScale: Int) -> CGSize {
        CGSize(width: imageWidth * outputScale, height: imageHeight * outputScale)
    }
}
