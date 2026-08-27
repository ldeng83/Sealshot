import AppKit

/// Bakes the editor's focus indicator (dimmed exterior + white viewfinder
/// bracket) into a Quick Look preview image, so a focused capture shows WHERE
/// the focus is instead of just the whole frame. Only applied when the focus
/// region is genuinely smaller than the image — a full-frame focus adds nothing.
enum FocusPreviewIndicator {

    /// Express `focus` (in the visible content's 1× coords, top-left origin) as
    /// a normalized [0,1] rect of that content. Returns nil when there is no
    /// meaningful sub-region to highlight: no focus, a degenerate rect, or a
    /// focus that covers ~the entire image (≥ 99% on both axes). Pure.
    static func normalizedFocus(focus: CGRect?, visibleSize: CGSize) -> CGRect? {
        guard let focus, visibleSize.width > 0, visibleSize.height > 0,
              focus.width > 0, focus.height > 0 else { return nil }
        let nw = focus.width / visibleSize.width
        let nh = focus.height / visibleSize.height
        // "Not the entire image" — at least one axis meaningfully smaller.
        guard !(nw >= 0.99 && nh >= 0.99) else { return nil }
        let x = min(max(focus.minX / visibleSize.width, 0), 1)
        let y = min(max(focus.minY / visibleSize.height, 0), 1)
        let w = min(nw, 1 - x)
        let h = min(nh, 1 - y)
        guard w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Crop `image` to the focus region (a [0,1] top-left-origin rect from
    /// `normalizedFocus`). This is what EXPORTS use — a focused capture
    /// exports just the focus area, matching the editor's Export to Image
    /// (`render(focus:)` crops the same way). The bracket-baked variant below
    /// stays preview-only (Quick Look), where showing WHERE the focus sits on
    /// the full frame is the point.
    static func imageCroppedToFocus(_ image: NSImage, normalized: CGRect) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // CGImage.cropping uses top-left-origin pixel coords — same orientation
        // as the normalized rect; no flip needed.
        let rect = CGRect(x: normalized.minX * w, y: normalized.minY * h,
                          width: normalized.width * w, height: normalized.height * h)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let cropped = cg.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: CGSize(width: rect.width, height: rect.height))
    }

    /// A copy of `image` with the focus indicator baked in. `normalized` is a
    /// [0,1] top-left-origin rect (from `normalizedFocus`). Uses an explicit
    /// bitmap rep (not `lockFocus`) so it is safe off the main thread and pins
    /// the output to the image's own size. Matches the editor: exterior dimmed
    /// 45%, a thin white outline, and thicker white corner brackets.
    static func imageWithFocusIndicator(_ image: NSImage, normalized: CGRect) -> NSImage {
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { return image }
        let pw = max(1, Int(size.width.rounded()))
        let ph = max(1, Int(size.height.rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let nsctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return image }
        rep.size = size
        let out = NSImage(size: size)
        out.addRepresentation(rep)

        // AppKit bottom-left origin: flip the normalized (top-left) rect.
        let fr = CGRect(x: normalized.minX * size.width,
                        y: (1 - normalized.maxY) * size.height,
                        width: normalized.width * size.width,
                        height: normalized.height * size.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        image.draw(in: CGRect(origin: .zero, size: size))

        // Dim everything outside the focus rect (matches the editor's 0.45).
        NSColor.black.withAlphaComponent(0.45).setFill()
        let dim = NSBezierPath(rect: CGRect(origin: .zero, size: size))
        dim.append(NSBezierPath(rect: fr).reversed)
        dim.windingRule = .evenOdd
        dim.fill()

        // Thin full outline + thicker corner brackets (viewfinder).
        let unit = max(1, min(size.width, size.height) / 320)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(rect: fr)
        outline.lineWidth = unit
        outline.stroke()

        let armLen = max(unit * 5, min(fr.width, fr.height) * 0.14)
        let bracket = NSBezierPath()
        bracket.lineWidth = unit * 2.4
        bracket.lineCapStyle = .round
        func corner(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
            bracket.move(to: CGPoint(x: p.x + dx * armLen, y: p.y))
            bracket.line(to: p)
            bracket.line(to: CGPoint(x: p.x, y: p.y + dy * armLen))
        }
        corner(CGPoint(x: fr.minX, y: fr.minY), 1, 1)   // bottom-left
        corner(CGPoint(x: fr.maxX, y: fr.minY), -1, 1)  // bottom-right
        corner(CGPoint(x: fr.minX, y: fr.maxY), 1, -1)  // top-left
        corner(CGPoint(x: fr.maxX, y: fr.maxY), -1, -1) // top-right
        NSColor.white.setStroke()
        bracket.stroke()

        nsctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
