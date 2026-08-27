import CoreGraphics

/// Composites several displays' captures into one image at their spatial layout,
/// for "All Displays" full-screen capture.
///
/// `tiles` are `(pointFrame, image)` pairs: `pointFrame` is the display's frame in
/// the global point-space arrangement (Cocoa `NSScreen.frame`, bottom-left origin),
/// and `image` is that display's capture at its own native pixel size. The layout
/// is done entirely in point-space and rendered at a single uniform `outputScale`
/// (pixels per point), so each image is resampled into its point-footprint —
/// `pointFrame.size × outputScale`. This keeps mixed-DPI layouts geometrically
/// correct: every display sits at its true relative position and size regardless of
/// per-display backing scale (a lower-DPI display is upscaled — approximate, but no
/// squashing or black gaps). The result spans the union of all frames with a
/// top-left origin. Returns nil for an empty input.
enum MultiDisplayStitcher {

    static func stitch(_ tiles: [(pointFrame: CGRect, image: CGImage)],
                       outputScale: CGFloat) -> CGImage? {
        guard let first = tiles.first, outputScale > 0 else { return nil }
        let union = tiles.dropFirst().reduce(first.pointFrame) { $0.union($1.pointFrame) }
        let w = Int((union.width * outputScale).rounded())
        let h = Int((union.height * outputScale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // CGContext is bottom-left origin; the point arrangement is bottom-left too
        // (Cocoa global coords), so each tile draws at its offset from the union
        // origin with no extra flip. Positioning AND sizing both use outputScale, so
        // the offset grid and each tile's footprint stay consistent — the source of
        // the mixed-DPI stitching bug was sizing tiles by raw native pixels while
        // offsetting by points × a single scale.
        for tile in tiles {
            let rect = CGRect(x: (tile.pointFrame.minX - union.minX) * outputScale,
                              y: (tile.pointFrame.minY - union.minY) * outputScale,
                              width: tile.pointFrame.width * outputScale,
                              height: tile.pointFrame.height * outputScale)
            ctx.draw(tile.image, in: rect)
        }
        return ctx.makeImage()
    }
}
