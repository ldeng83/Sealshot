import CoreGraphics

/// Pixel-based browser chrome/page split — the PERMISSION-FREE fallback for
/// the page-body hover candidate. When the AX probe can't answer (no
/// Accessibility grant, or the browser serves no usable tree), the frozen
/// window image itself still shows where the chrome ends: the boundary is a
/// full-window-width horizontal edge in a narrow band below the window top.
///
/// Deliberately much narrower than the generic `BoundaryDetector` (whose
/// thresholds were raised because speculative rects made hovering jumpy):
/// this only ever answers ONE question — "how tall is the chrome?" — for
/// windows already known to be browsers, and returns nil rather than guess.
/// AX results always take precedence (see `hoverBoundaryRects`).
enum BrowserChromeSplit {

    struct Params {
        /// Plausible chrome heights, in points from the window's top edge.
        /// Tab strip + address bar ≈ 75–120pt; add a bookmarks bar and an
        /// info banner and ~240pt is the realistic ceiling. Below `bandTop`
        /// is title-bar/tab-strip territory, never the content boundary.
        var bandTop: CGFloat = 30
        var bandBottom: CGFloat = 240
        /// A chrome boundary spans (essentially) the whole window width:
        /// the fraction of sampled columns that must show a gradient at the
        /// row. In-page edges (cards, headers in a centered column) fail this.
        var minCoverage: Double = 0.88
        /// Minimum per-pixel luminance step (0–255). Light-theme divider
        /// hairlines are subtle; 8 catches them while `minCoverage` keeps
        /// texture noise out.
        var minGradient: Int = 8
        /// Columns skipped at each side (window borders/shadows) and the
        /// sampling stride across the width.
        var sideInsetFraction: CGFloat = 0.02
        var columnStride: Int = 3
        /// A real page is at least this tall below the split.
        var minContentHeight: CGFloat = 80
        static let standard = Params()
    }

    /// The browser-chrome height in POINTS from the window's top edge, or
    /// nil when no qualifying full-width horizontal edge exists in the band.
    /// `windowImage` is the window's pixels, row 0 = window top (what
    /// `FrozenFrameCrop.crop` yields); `pixelsPerPoint` is the display scale.
    static func chromeHeight(in windowImage: CGImage,
                             pixelsPerPoint: CGFloat,
                             params: Params = .standard) -> CGFloat? {
        let scale = max(pixelsPerPoint, 0.5)
        let width = windowImage.width
        let height = windowImage.height
        let bandTopPx = Int(params.bandTop * scale)
        // The split must leave real content below it — clamp the band so a
        // qualifying edge always satisfies the content minimum.
        let bandBottomPx = min(Int(params.bandBottom * scale),
                               height - Int(params.minContentHeight * scale)) - 1
        guard width > 16, bandBottomPx > bandTopPx else { return nil }

        // Grayscale-render just the band (plus one row for the gradient).
        let rows = bandBottomPx + 2
        guard rows <= height,
              let band = windowImage.cropping(
                to: CGRect(x: 0, y: 0, width: width, height: rows)),
              let ctx = CGContext(
                data: nil, width: width, height: rows, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(band, in: CGRect(x: 0, y: 0, width: width, height: rows))
        guard let data = ctx.data else { return nil }
        let stride = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: stride * rows)
        // Bitmap memory row 0 is the TOP scanline (CG coords are bottom-left,
        // but the buffer is laid out top-down), so buffer row == image row.
        func lum(_ imageRow: Int, _ x: Int) -> Int {
            Int(px[imageRow * stride + x])
        }

        let inset = Int(CGFloat(width) * params.sideInsetFraction)
        let xs = Swift.stride(from: inset, to: width - inset, by: max(1, params.columnStride))
        let sampleCount = xs.underestimatedCount
        guard sampleCount > 8 else { return nil }

        for y in bandTopPx..<bandBottomPx {
            var hits = 0
            for x in xs where abs(lum(y + 1, x) - lum(y, x)) >= params.minGradient {
                hits += 1
            }
            if Double(hits) / Double(sampleCount) >= params.minCoverage {
                return CGFloat(y + 1) / scale
            }
        }
        return nil
    }
}
