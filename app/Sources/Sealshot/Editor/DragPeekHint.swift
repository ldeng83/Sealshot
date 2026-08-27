import AppKit

/// The peek gesture has no menu item and no shortcut row, so without a hint it
/// is undiscoverable. The caption rides on the drag image itself.
///
/// The pill matches the strip's existing duration badge (`drawDurationBadge`):
/// black at 0.6 alpha, 4pt radius, white semibold text.
enum DragPeekHint {

    static let text = "Hold ctrl ^ to hide window"

    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let padX: CGFloat = 5
    private static let padY: CGFloat = 2
    private static let gap: CGFloat = 4

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.white]
    }

    /// `image` with the hint pill ABOVE it. The original is drawn at the BOTTOM
    /// of the taller canvas, so pairing this with `frame(forOriginal:…)` — which
    /// pins the bottom edge — leaves the thumbnail exactly where the user
    /// grabbed it.
    static func compose(_ image: NSImage) -> NSImage {
        let textSize = (text as NSString).size(withAttributes: attributes)
        let pillSize = NSSize(width: textSize.width + padX * 2,
                              height: textSize.height + padY * 2)
        let canvas = NSSize(width: max(image.size.width, pillSize.width),
                            height: image.size.height + gap + pillSize.height)

        // NSImage(size:flipped:drawingHandler:) rasterises at whatever scale
        // the destination needs, so the strip's 720px tile is not flattened to
        // a fixed-scale bitmap before AppKit stretches it back up for display —
        // lockFocus()/unlockFocus() rasterise at a fixed scale, which is
        // pixel-equivalent on Retina but visibly soft on a 1x display.
        //
        // Coordinates are y-up (flipped: false), so y = 0 is the BOTTOM.
        return NSImage(size: canvas, flipped: false) { _ in
            image.draw(at: NSPoint(x: ((canvas.width - image.size.width) / 2).rounded(),
                                   y: 0),                       // thumbnail at the bottom
                       from: .zero, operation: .sourceOver, fraction: 1)
            let pill = NSRect(x: ((canvas.width - pillSize.width) / 2).rounded(),
                              y: canvas.height - pillSize.height,   // caption on top
                              width: pillSize.width, height: pillSize.height)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            (text as NSString).draw(at: NSPoint(x: pill.minX + padX, y: pill.minY + padY),
                                    withAttributes: attributes)
            return true
        }
    }

    /// The dragging frame for a composed image: grows UPWARD (higher `maxY`)
    /// and widens symmetrically, so the original content keeps its position
    /// under the pointer.
    ///
    /// The BOTTOM edge is the anchor because `compose` draws the thumbnail at
    /// the bottom of the canvas and the caption above it. Pinning the top edge
    /// instead — as this did while the caption sat underneath — would shove the
    /// thumbnail down by the caption's height the moment the drag started.
    ///
    /// Ratios, not deltas: `rect` is the caller's FRAME (point space) while
    /// `composed`/`original` are IMAGE sizes, and at the real call site those
    /// bases differ — tile images are built at PIXEL dimensions
    /// (`CaptureThumbnail.downsampledImage`) while the drag frame is point
    /// space. Subtracting one from the other produced a frame several times
    /// too large; scaling by ratio preserves the caller's units whatever they are.
    static func frame(forOriginal rect: NSRect, composed: NSSize,
                      original: NSSize) -> NSRect {
        guard original.width > 0, original.height > 0 else { return rect }
        let newWidth = rect.width * (composed.width / original.width)
        let newHeight = rect.height * (composed.height / original.height)
        return NSRect(x: rect.midX - newWidth / 2,     // widen symmetrically
                      y: rect.minY,                    // grow UPWARD: bottom edge fixed
                      width: newWidth,
                      height: newHeight)
    }

    /// Compose the hint for a drag item whose contents will be STRETCHED to
    /// `frame`, returning the image and the adjusted frame together.
    ///
    /// The source is first redrawn at `frame`'s size so the pill is composed in
    /// the same space it will be displayed in. Without this, the caption is
    /// drawn inside the image's own coordinate space — and strip tile images are
    /// PIXEL-sized (up to 720px) while their frame is ~117pt, so the caption
    /// would be scaled down ~6x on screen and be unreadable.
    static func composed(for image: NSImage, in frame: NSRect) -> (image: NSImage, frame: NSRect) {
        // A zero-sized NSImage raises an uncatchable Objective-C exception
        // when drawn into. Unreachable from today's call sites, but
        // `frame(forOriginal:composed:original:)` already guards its
        // degenerate input, so this should be symmetric.
        guard frame.size.width > 0, frame.size.height > 0 else { return (image, frame) }
        let normalized = NSImage(size: frame.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        let hinted = compose(normalized)
        return (hinted, self.frame(forOriginal: frame,
                                   composed: hinted.size,
                                   original: frame.size))
    }
}
