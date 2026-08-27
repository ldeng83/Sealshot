import AppKit

/// Pure zoom math for the in-canvas video player (unit-tested; mirrors the
/// image canvas's conventions — fit never upscales, manual zoom tops at 8×).
enum VideoZoomMath {
    static let maxZoom: CGFloat = 8.0
    static let zoomStep: CGFloat = 1.25

    /// Fit-to-window zoom: the video fills the viewport on its limiting axis,
    /// but auto-fit never upscales past native (capped at 1.0). Inset is 0 —
    /// matching the player's current edge-to-edge on-open framing. Degenerate
    /// sizes fall back to 1.0.
    static func fitZoom(videoSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard videoSize.width > 0, videoSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1.0 }
        return min(viewportSize.width / videoSize.width,
                   viewportSize.height / videoSize.height,
                   1.0)
    }

    /// Clamp a requested zoom to [fit … maxZoom] — fit is the floor (there is
    /// nothing to see beyond the letterbox), 8× the manual ceiling.
    static func clamp(_ zoom: CGFloat, fit: CGFloat) -> CGFloat {
        max(fit, min(maxZoom, zoom))
    }
}

/// Magnifying scroll view for the in-canvas video player. Mirrors the image
/// canvas's zoom mechanism: the document view stays at the video's NATIVE
/// pixel size and zoom is applied as GPU magnification — the document frame
/// NEVER grows with zoom. (Resizing it with zoom is what ballooned the CA
/// backing store to multi-GB and hung the app in the reverted first attempt.)
@MainActor
final class VideoZoomScrollView: NSScrollView {

    /// Native video pixel size; nil until the track's naturalSize loads —
    /// until then the document tracks the viewport (gravity letterboxes).
    private(set) var videoSize: CGSize?
    /// Reported after every zoom change (buttons, slider, pinch, ⌘-scroll,
    /// resize clamps) so the owner can mirror it in the meta row.
    var onZoomChanged: ((CGFloat) -> Void)?
    var zoom: CGFloat { magnification }

    private let centerClip = VideoCenteringClipView()

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .black
        // Zoom is applied as scroll-view magnification (a GPU transform): the
        // document view stays at native size, so the layer backing store never
        // balloons to `videoSize × zoom`.
        allowsMagnification = true
        maxMagnification = VideoZoomMath.maxZoom
        minMagnification = 1.0   // refined to the fit floor once the size is known
        centerClip.drawsBackground = true
        centerClip.backgroundColor = .black
        contentView = centerClip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Called once the video track's naturalSize is known: pin the document
    /// to native pixels and open at fit.
    func setVideoSize(_ size: CGSize) {
        videoSize = size
        layoutDocument()
        fitToWindow()
    }

    private var currentFit: CGFloat {
        guard let v = videoSize else { return 1.0 }
        return VideoZoomMath.fitZoom(videoSize: v, viewportSize: contentSize)
    }

    private func layoutDocument() {
        guard let doc = documentView else { return }
        doc.translatesAutoresizingMaskIntoConstraints = true
        if let v = videoSize {
            doc.frame = CGRect(origin: .zero, size: v)   // NATIVE — never scaled
        } else {
            doc.frame = CGRect(origin: .zero, size: contentSize)
        }
    }

    override func layout() {
        super.layout()
        if videoSize == nil { layoutDocument() }   // track the viewport until known
        // Window resize moves the fit floor: a video left at/below the new fit
        // snaps to it; a deliberately zoomed-in video keeps its zoom.
        let fit = currentFit
        minMagnification = min(fit, VideoZoomMath.maxZoom)
        if magnification < minMagnification { applyZoom(minMagnification) }
    }

    // MARK: - Zoom API (mirrors EditorCanvasScrollView's shape)

    func zoomIn()  { applyZoom(zoom * VideoZoomMath.zoomStep) }
    func zoomOut() { applyZoom(zoom / VideoZoomMath.zoomStep) }
    func setZoom(_ z: CGFloat) { applyZoom(z) }
    func actualSize() { applyZoom(1.0) }

    func fitToWindow() {
        let fit = currentFit
        minMagnification = min(fit, VideoZoomMath.maxZoom)
        applyZoom(fit)
        // Re-center: NSClipView.scroll(to:) sets the origin directly, so ask
        // the centering constraint for the centered/clamped origin (same
        // technique as the image canvas's recenterAfterFit).
        let centered = centerClip.constrainBoundsRect(
            CGRect(origin: .zero, size: centerClip.bounds.size)).origin
        centerClip.scroll(to: centered)
        reflectScrolledClipView(centerClip)
    }

    /// Apply a clamped zoom keeping the document point at the viewport centre
    /// fixed, then report the change. Implemented as an explicit
    /// magnify-then-recentre rather than `setMagnification(_:centeredAt:)` —
    /// that API interpreted the anchor in document coordinates, so a
    /// viewport-centre point (small values) anchored the zoom toward the
    /// document's lower-left.
    private func applyZoom(_ z: CGFloat) {
        let clamped = VideoZoomMath.clamp(z, fit: currentFit)
        let clip = contentView
        // Document point currently at the viewport centre (the clip view's
        // bounds are expressed in document coordinates).
        let anchor = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        magnification = clamped
        // The clip's bounds size changed with the zoom — scroll so the same
        // document point is centred again. constrainBoundsRect applies the
        // centring/edge clamps (smaller-than-viewport content stays centred).
        let target = NSRect(origin: NSPoint(x: anchor.x - clip.bounds.width / 2,
                                            y: anchor.y - clip.bounds.height / 2),
                            size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        reflectScrolledClipView(clip)
        onZoomChanged?(clamped)
    }

    /// ⌘-scroll zooms (viewport-centre anchored), reusing the image canvas's
    /// (already unit-tested) sensitivity math; plain scroll pans as normal.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let next = EditorCanvasScrollView.zoomByScroll(
                zoom, scrollDeltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas)
            applyZoom(next)
            return
        }
        super.scrollWheel(with: event)
    }

    /// Pinch zooms anchored at the viewport centre: self-driven (super's
    /// native handling anchors at the gesture location, which was dropped
    /// along with cursor-anchored ⌘-scroll). `event.magnification` is the
    /// relative delta for this event.
    override func magnify(with event: NSEvent) {
        applyZoom(zoom * (1 + event.magnification))
    }
}

/// Clip view that recenters a smaller-than-viewport document instead of the
/// default bottom-left pinning (the centering half of the image canvas's
/// CenteringClipView; no focus-limit machinery — video has none).
private final class VideoCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}
