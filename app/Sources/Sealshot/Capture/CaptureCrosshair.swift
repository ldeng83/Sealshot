import AppKit

/// Pure placement math for the standardized capture crosshair: full-screen
/// hairlines with a center gap, the info badge, and the magnifier loupe.
/// View coordinates throughout (bottom-left origin); pixel mapping for the
/// loupe is FrozenFrameCrop's job. See CaptureCrosshairGeometryTests.
enum CrosshairGeometry {

    struct Hairlines: Equatable {
        let above: CGRect
        let below: CGRect
        let left: CGRect
        let right: CGRect
    }

    /// Four hairline segments through `point`, stopping `gap` short of it so
    /// the target pixel stays visible. Segments collapse to zero length near
    /// the bounds edges rather than going negative.
    static func hairlines(
        at point: CGPoint, in bounds: CGRect, gap: CGFloat, thickness: CGFloat
    ) -> Hairlines {
        let vx = point.x - thickness / 2
        let hy = point.y - thickness / 2
        return Hairlines(
            above: CGRect(x: vx, y: point.y + gap, width: thickness,
                          height: max(0, bounds.maxY - (point.y + gap))),
            below: CGRect(x: vx, y: bounds.minY, width: thickness,
                          height: max(0, point.y - gap - bounds.minY)),
            left: CGRect(x: bounds.minX, y: hy,
                         width: max(0, point.x - gap - bounds.minX), height: thickness),
            right: CGRect(x: point.x + gap, y: hy,
                          width: max(0, bounds.maxX - (point.x + gap)), height: thickness))
    }

    /// Origin for a badge of `size` near `point`: below-right by `offset`,
    /// flipping per axis to stay inside `bounds`.
    static func badgeOrigin(
        near point: CGPoint, size: CGSize, in bounds: CGRect, offset: CGFloat
    ) -> CGPoint {
        var x = point.x + offset
        if x + size.width > bounds.maxX { x = point.x - offset - size.width }
        var y = point.y - offset - size.height
        if y < bounds.minY { y = point.y + offset }
        return CGPoint(x: x, y: y)
    }

    /// Loupe placement: same flip rules as the badge, square of `diameter`.
    static func loupeOrigin(
        near point: CGPoint, diameter: CGFloat, in bounds: CGRect, offset: CGFloat
    ) -> CGPoint {
        badgeOrigin(near: point, size: CGSize(width: diameter, height: diameter),
                    in: bounds, offset: offset)
    }

    /// The view-coordinate region the loupe magnifies: `diameter / zoom` pts
    /// centered on `center`, shifted (size preserved) to stay inside `bounds`.
    static func loupeSourceViewRect(
        center: CGPoint, zoom: CGFloat, diameter: CGFloat, in bounds: CGRect
    ) -> CGRect {
        let side = diameter / zoom
        var rect = CGRect(x: center.x - side / 2, y: center.y - side / 2,
                          width: side, height: side)
        if rect.maxX > bounds.maxX { rect.origin.x = bounds.maxX - side }
        if rect.maxY > bounds.maxY { rect.origin.y = bounds.maxY - side }
        if rect.minX < bounds.minX { rect.origin.x = bounds.minX }
        if rect.minY < bounds.minY { rect.origin.y = bounds.minY }
        return rect
    }
}

/// Shared drawing for the standardized capture crosshair. Every overlay view
/// (`SelectionView`, `UnifiedSelectionView`, `WindowHighlightView`) calls
/// `draw(at:in:primary:hints:loupeImage:)` from its `draw(_:)`; placement
/// comes from `CrosshairGeometry`.
@MainActor
enum CrosshairRender {
    static let gap: CGFloat = 7
    static let thickness: CGFloat = 1
    static let badgeOffset: CGFloat = 18
    static let loupeOffset: CGFloat = 24
    static let loupeDiameter: CGFloat = 130
    static let loupeZoom: CGFloat = 3

    /// Per-mode hint lines shown under the coordinates while idle — the hint
    /// is how the user tells the otherwise identical overlays apart.
    enum Hints {
        static let unified = ["Drag to capture an area",
                              "⌘-drag to adjust before capturing"]
        static let unifiedFrozen = ["Screen frozen — menus & tooltips survive"] + unified
        static let region = ["Drag to capture an area"]
        static let scroll = ["Drag to select the scroll area",
                             "⌘-drag to adjust before capturing"]
        static let windowPick = ["Click a window to capture it"]
        /// Repeat capture fell back to selection: say why the overlay appeared
        /// rather than leaving the user wondering what happened to "repeat".
        /// Two different situations, and telling a first-time user their screen
        /// is unavailable would be a lie about a machine that is working fine.
        static let repeatNothingYet = ["No area captured yet — drag one",
                                       "Repeat captures it again from then on"]
        static let repeatUnavailable = ["That area's screen is no longer available",
                                        "Drag a new one — it becomes the repeat area"]
    }

    /// A 1×1 clear cursor: hides the system cursor while a capture overlay is
    /// up without `NSCursor.hide()`'s app-global pairing hazard — the real
    /// cursor comes back by itself when the panels close.
    static let transparentCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// Hairlines + center dot + badge + (optional) loupe, in one call.
    /// `primary` is the badge's monospaced first line (coordinates or
    /// dimensions); `hints` render smaller beneath it.
    static func draw(
        at point: CGPoint, in bounds: CGRect,
        primary: String, hints: [String], loupeImage: CGImage?
    ) {
        drawHairlines(at: point, in: bounds)

        var loupeFrame: CGRect?
        if let image = loupeImage {
            let origin = CrosshairGeometry.loupeOrigin(
                near: point, diameter: loupeDiameter, in: bounds, offset: loupeOffset)
            let frame = CGRect(origin: origin,
                               size: CGSize(width: loupeDiameter, height: loupeDiameter))
            LoupeRenderer.draw(source: image, in: frame, focus: point, viewBounds: bounds)
            loupeFrame = frame
        }

        let size = badgeSize(primary: primary, hints: hints)
        let origin: CGPoint
        if let loupe = loupeFrame {
            // Anchor under the loupe so the two never overlap; flip above it
            // when there is no room below.
            var o = CGPoint(x: loupe.minX, y: loupe.minY - 6 - size.height)
            if o.y < bounds.minY { o.y = loupe.maxY + 6 }
            o.x = min(o.x, bounds.maxX - size.width)
            origin = o
        } else {
            origin = CrosshairGeometry.badgeOrigin(
                near: point, size: size, in: bounds, offset: badgeOffset)
        }
        drawBadge(primary: primary, hints: hints, at: origin, size: size)
    }

    /// Where the badge lands for `point`, given the loupe frame it anchors to.
    /// Exposed so a caller drawing ONLY the badge (because layers now handle
    /// the hairlines and loupe) can both place it and invalidate just its
    /// region, instead of the screen-spanning crosshair.
    static func badgeFrame(at point: CGPoint, in bounds: CGRect,
                           primary: String, hints: [String],
                           loupeFrame: CGRect?) -> CGRect {
        let size = badgeSize(primary: primary, hints: hints)
        let origin: CGPoint
        if let loupe = loupeFrame {
            var o = CGPoint(x: loupe.minX, y: loupe.minY - 6 - size.height)
            if o.y < bounds.minY { o.y = loupe.maxY + 6 }
            o.x = min(o.x, bounds.maxX - size.width)
            origin = o
        } else {
            origin = CrosshairGeometry.badgeOrigin(
                near: point, size: size, in: bounds, offset: badgeOffset)
        }
        return CGRect(origin: origin, size: size)
    }

    /// The loupe's frame for `point` — the badge anchors under it, and the
    /// layer-based loupe needs the same placement.
    static func loupeFrame(at point: CGPoint, in bounds: CGRect) -> CGRect {
        CGRect(origin: CrosshairGeometry.loupeOrigin(
                    near: point, diameter: loupeDiameter,
                    in: bounds, offset: loupeOffset),
               size: CGSize(width: loupeDiameter, height: loupeDiameter))
    }

    /// Draw ONLY the badge. Used by overlays whose hairlines and loupe are
    /// CALayers (see `CrosshairLayers`), so the sole thing left in `draw(_:)`
    /// is a small box near the cursor rather than a full-screen cross.
    static func drawBadgeOnly(at point: CGPoint, in bounds: CGRect,
                              primary: String, hints: [String],
                              loupeFrame: CGRect?) {
        let frame = badgeFrame(at: point, in: bounds, primary: primary,
                               hints: hints, loupeFrame: loupeFrame)
        drawBadge(primary: primary, hints: hints, at: frame.origin, size: frame.size)
    }

    static func drawHairlines(at point: CGPoint, in bounds: CGRect) {
        let lines = CrosshairGeometry.hairlines(
            at: point, in: bounds, gap: gap, thickness: thickness)
        let halo = NSColor.black.withAlphaComponent(0.4)
        let core = NSColor.white.withAlphaComponent(0.95)
        for rect in [lines.above, lines.below, lines.left, lines.right]
        where rect.width > 0 && rect.height > 0 {
            halo.setFill()
            rect.insetBy(dx: -0.5, dy: -0.5).fill()
            core.setFill()
            rect.fill()
        }
        let dot = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        halo.setFill()
        dot.insetBy(dx: -1, dy: -1).fill()
        NSColor.white.setFill()
        dot.fill()
    }

    /// Pixel coordinates of the cursor, top-left origin to match the captured
    /// image (and what users expect of screen coordinates).
    static func coordsText(point: CGPoint, viewHeight: CGFloat, scale: CGFloat) -> String {
        let x = Int((point.x * scale).rounded())
        let y = Int(((viewHeight - point.y) * scale).rounded())
        return "\(x), \(y)"
    }

    /// Pixel-size + PPI readout, same format as the readout it replaces.
    static func dimensionsText(rect: CGRect, scale: CGFloat, ppi: CGFloat) -> String {
        let pxW = Int((rect.width * scale).rounded())
        let pxH = Int((rect.height * scale).rounded())
        var text = "\(pxW) × \(pxH)"
        if ppi > 0 { text += "  ·  \(Int(ppi.rounded())) PPI" }
        return text
    }

    // MARK: - Badge internals

    private static let badgePadX: CGFloat = 10
    private static let badgePadY: CGFloat = 7
    private static let badgeLineGap: CGFloat = 3

    // Fonts and attribute dictionaries are built ONCE. A tester crash showed
    // CoreText's TAttributes::ApplyFont throwing (nil materializing in CF
    // attribute assembly) under sizeWithAttributes — rebuilding the font +
    // bridged dictionary on every measure/draw call, at redraw frequency,
    // maximizes exposure to that race and is wasted work besides.
    private static let primaryAttrs: [NSAttributedString.Key: Any] =
        [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
         .foregroundColor: NSColor.white]

    private static let hintAttrs: [NSAttributedString.Key: Any] =
        [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
         .foregroundColor: NSColor.white.withAlphaComponent(0.82)]

    /// Hint strings are a handful of fixed phrases redrawn every frame —
    /// measure each once. Main-thread only (drawing).
    private static var hintSizeCache: [String: CGSize] = [:]

    private static func hintSize(_ hint: String) -> CGSize {
        if let cached = hintSizeCache[hint] { return cached }
        let size = (hint as NSString).size(withAttributes: hintAttrs)
        hintSizeCache[hint] = size
        return size
    }

    private static func badgeSize(primary: String, hints: [String]) -> CGSize {
        let primarySize = (primary as NSString).size(withAttributes: primaryAttrs)
        let hintSizes = hints.map(hintSize)
        let textW = ([primarySize.width] + hintSizes.map(\.width)).max() ?? 0
        let textH = primarySize.height + hintSizes.reduce(0) { $0 + badgeLineGap + $1.height }
        return CGSize(width: textW + badgePadX * 2, height: textH + badgePadY * 2)
    }

    private static func drawBadge(
        primary: String, hints: [String], at origin: CGPoint, size: CGSize
    ) {
        let box = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()

        let primarySize = (primary as NSString).size(withAttributes: primaryAttrs)
        var y = box.maxY - badgePadY - primarySize.height
        (primary as NSString).draw(
            at: CGPoint(x: box.minX + badgePadX, y: y), withAttributes: primaryAttrs)
        for hint in hints {
            let size = hintSize(hint)
            y -= badgeLineGap + size.height
            (hint as NSString).draw(
                at: CGPoint(x: box.minX + badgePadX, y: y), withAttributes: hintAttrs)
        }
    }
}
