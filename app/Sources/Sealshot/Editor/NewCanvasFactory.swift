import AppKit

/// Builds the CGImage for scratch editor sessions: a blank transparent canvas,
/// or one seeded from the clipboard. Pure image construction — presentation and
/// persistence are the coordinator's and save path's jobs.
enum NewCanvasFactory {

    static let defaultSize = CGSize(width: 800, height: 500)

    /// Fully transparent canvas. The editor shows a checkerboard behind it and
    /// the (nil) backgroundFill keeps exports transparent until the user picks a
    /// fill via the canvas Background menu. Nil only if the context can't be
    /// created (degenerate size).
    static func blank(size: CGSize = defaultSize) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Whether `image` is a still-blank canvas — every pixel fully
    /// transparent, as `blank(size:)` produces.
    ///
    /// Used to tell "an empty drawing surface" apart from "a capture", which
    /// decides whether a pasted image too big to fit grows the canvas or is
    /// scaled down onto it. Scans until the first non-transparent pixel, so a
    /// screenshot (opaque from its first row) costs almost nothing; only a
    /// genuinely blank canvas is read in full, and at 800×500 that is well
    /// under a millisecond.
    static func isBlankCanvas(_ image: CGImage) -> Bool {
        // No alpha at all ⇒ opaque ⇒ not blank, without touching a pixel.
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 4, image.bitsPerComponent == 8 else { return false }
        // Alpha is the last component for premultipliedLast/alphaLast (what
        // `blank` writes) and the first for the *First variants.
        let alphaOffset: Int
        switch image.alphaInfo {
        case .premultipliedFirst, .first: alphaOffset = 0
        default: alphaOffset = bpp - 1
        }
        var index = alphaOffset
        while index < length {
            if bytes[index] != 0 { return false }
            index += bpp
        }
        return true
    }

    /// First image on the pasteboard at its full pixel size, nil when none.
    static func fromClipboard(_ pasteboard: NSPasteboard = .general) -> CGImage? {
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        var rect = CGRect(origin: .zero,
                          size: largestRepPixelSize(of: image) ?? image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Drives the ⇧⌘N menu item's enabled state.
    static func clipboardHasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// NSImage.size is in points; ask the bitmap rep for true pixels so a
    /// Retina clipboard image isn't halved.
    private static func largestRepPixelSize(of image: NSImage) -> CGSize? {
        image.representations
            .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .filter { $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }
}
