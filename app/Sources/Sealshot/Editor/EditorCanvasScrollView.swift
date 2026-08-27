import AppKit
import Observation

/// NSScrollView wrapping `EditorCanvasView` and providing zoom + pan.
///
/// Zoom is stored on `EditorState.zoom`. The scroll view observes that
/// value and resizes the canvas's frame to `imageSize * zoom` plus a fixed
/// `EditorCanvasView.imagePadding` border on each side. The canvas's
/// `currentScale()` backs that padding out so it still renders at the true
/// zoom; the padding just gives boundary anchor dots real canvas around
/// them. Annotations stay in image-space and render correctly at any zoom.
@MainActor
final class EditorCanvasScrollView: NSScrollView {

    nonisolated static let minZoom: CGFloat = 0.10
    // Auto-fit (the "Fit" button and the initial fit-to-window) never
    // upscales past native pixels — a small image tops out at 100% so it
    // isn't blown up and blurred to fill the viewport.
    static let fitMaxZoom: CGFloat = 1.0
    // Manual zoom — the + button and typed percentages — may exceed 100%.
    // 100% is no longer a hard limit for deliberate user zoom; this is just
    // a safety ceiling so the canvas frame can't grow without bound.
    nonisolated static let manualMaxZoom: CGFloat = 8.0
    static let zoomStep: CGFloat = 1.25
    static let fitInset: CGFloat = 16
    // When fitting a focus crop, leave the focus rect filling only this much of
    // the viewport so a margin of dimmed image stays visible around it — giving
    // the user room to grab an anchor and drag it back out to enlarge the focus.
    // 1.0 = same tight 16pt inset as Fit (was 0.8; trial per user request).
    static let focusViewportFill: CGFloat = 1.0

    private let state: EditorState
    private let canvas: EditorCanvasView
    private var scrollObserver: NSObjectProtocol?
    private let centerClip = CenteringClipView()

    /// True only while the Focus button has us scrolling within the focus area.
    /// The whole-image zoom buttons (Fit, Fit Width, Fit Height, Original) turn
    /// this off — they zoom the whole image and scroll it normally — WITHOUT
    /// clearing `state.focusRect`, so the focus dimming stays visible.
    private var limitScrollToFocus = false

    /// True while a hand-tool focus pan is in progress. Suppresses the async
    /// `observeFocus` re-fit so moving the focus doesn't reset the user's zoom
    /// or fight the drag (which shows up as shaking). The pan re-centers at the
    /// CURRENT zoom itself via `setFocusDuringPan`.
    private var suppressFocusRefit = false

    /// Duration of the crop-commit cross-fade.
    private static let cropCommitDuration: CFTimeInterval = 0.25

    /// Set for the single `observeZoom` firing triggered by a crop commit, so
    /// the async observation doesn't re-snap the frame we already resized and
    /// re-centered SYNCHRONOUSLY in `commitCropSmoothly`. Without this the crop
    /// applied in two visible steps: the image redrew cropped, then the frame
    /// jumped to re-center a runloop tick later.
    private var suppressCropFrameSync = false

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    init(state: EditorState, canvas: EditorCanvasView) {
        self.state = state
        self.canvas = canvas
        super.init(frame: .zero)

        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        backgroundColor = .clear
        // Zoom is applied as scroll-view magnification (a GPU transform): the
        // document view stays at native size, so the layer backing store never
        // balloons to `imageSize × zoom` (which hung the app on large files).
        // We drive/clamp magnification manually from `state.zoom`.
        allowsMagnification = true
        minMagnification = Self.minZoom
        maxMagnification = Self.manualMaxZoom

        // Custom clip view centers a small document inside the viewport
        // rather than pinning it to the bottom-left default, and (while focused)
        // limits scrolling to the focus area.
        centerClip.drawsBackground = false
        self.contentView = centerClip

        // NSClipView minimizes the document area it invalidates on scroll, so the
        // canvas's translucent focus dimming overlay isn't repainted in the
        // copied region — it tears/jumps. Repaint the visible canvas on every
        // scroll while a focus overlay is active so it moves smoothly.
        centerClip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: centerClip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.focusRect != nil else { return }
                self.canvas.setNeedsDisplay(self.canvas.visibleRect)
            }
        }

        canvas.translatesAutoresizingMaskIntoConstraints = true
        documentView = canvas

        applyZoomToCanvasFrame()
        observeZoom()
        observeFocus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Public zoom API

    /// Current GPU magnification (== state.zoom). Used by magnified canvas
    /// drawing that needs constant on-screen metrics.
    var chromeMagnification: CGFloat { magnification }

    /// ⌘+scroll zooms even when the pointer is over the scroll view's empty
    /// margin (outside the image canvas). When the pointer is over the canvas,
    /// `EditorCanvasView.scrollWheel` handles ⌘+scroll and consumes the event,
    /// so it never reaches here; this catches the off-image case. Plain scroll
    /// falls through to normal scrolling.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoomByScroll(scrollDeltaY: event.scrollingDeltaY,
                         precise: event.hasPreciseScrollingDeltas,
                         atWindowPoint: event.locationInWindow)
            return
        }
        super.scrollWheel(with: event)
    }

    func zoomIn() {
        setZoomPreservingFocalPoint(state.zoom * Self.zoomStep)
    }

    func zoomOut() {
        setZoomPreservingFocalPoint(state.zoom / Self.zoomStep)
    }

    func setZoom(_ z: CGFloat) {
        setZoomPreservingFocalPoint(z)
    }

    /// Apply a new zoom as a magnification about the viewport center, keeping
    /// the centered image point anchored. The document view stays native size;
    /// AppKit scales it on the GPU. fit operations route through
    /// `recenterAfterFit` (which re-centers via the clip view) instead.
    private func setZoomPreservingFocalPoint(_ newZoom: CGFloat) {
        // Always a user gesture (⌘±, slider, Original) — a ⌘Z step (coalesced).
        state.checkpointZoomIfNeeded()
        let clamped = Self.clampZoom(newZoom)
        state.zoom = clamped
        // `setMagnification(_:centeredAt:)` keeps the given point anchored, and
        // wants it "in content view space" (clip-view/document coordinates) —
        // convert the viewport middle into that space rather than passing raw
        // scroll-view bounds coordinates.
        let viewportMid = NSPoint(x: bounds.midX, y: bounds.midY)
        let anchor = contentView.convert(viewportMid, from: self)
        // This path bypasses `applyMagnification`, so the filter has to be set
        // here too — otherwise ⌘± and the zoom slider keep whatever filter the
        // last fit left behind.
        applyMagnificationFilter(for: clamped)
        withZoomGlide { animator().setMagnification(clamped, centeredAt: anchor) }
    }

    /// Discrete zoom changes (⌘±, Fit buttons, ⌘0, double-click-fit) GLIDE to
    /// the new magnification instead of snapping. Continuous ⌘+scroll
    /// deliberately stays unanimated — gesture ticks need immediate response.
    ///
    /// GOTCHA: `animator().magnify(toFit:)` does NOT land the model
    /// `magnification` synchronously, so callers must set `state.zoom` to the
    /// precomputed target themselves (never read it back), and the deferred
    /// `observeZoom` snap is suppressed while the glide is in flight — the
    /// completion re-runs `applyMagnification` to settle model + crisp filter.
    static let zoomGlideDuration: TimeInterval = 0.22
    private var zoomGlideInFlight = false
    private func withZoomGlide(_ apply: () -> Void) {
        zoomGlideInFlight = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.zoomGlideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            apply()
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.zoomGlideInFlight = false
                self.applyMagnification()
                // Then snap AGAIN a turn later.
                //
                // An upward glide can land a hair short of its target and stay
                // there: a trace of 70% -> 100% ended with the model at
                // stateZoom=1.0000 (so the UI reads 100%) while the scroll view
                // sat at magnification=0.9900. Everything downstream was then
                // correct FOR 99% — density in sync, blit at native — so the
                // image was a 1% resample of itself rather than the byte-exact
                // copy 100% should give. Gliding DOWN to 100% reached 1.0000
                // exactly, which is why only one direction looked wrong.
                //
                // The assignment above does not always take while the animator
                // is still unwinding, so re-assert once it has.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let z = Self.clampZoom(self.state.zoom)
                    // Settle the glide onto its target.
                    //
                    // `magnification` is the MODEL value: the animator sets it
                    // to the target the instant the glide starts, then animates
                    // what is actually applied. The applied value can stop a
                    // hair short and stay there — a trace of 70% -> 100% read
                    // `magBefore=1.0000` while the canvas layer sat at 0.9907.
                    // AppKit keeps that layer consistent with the APPLIED value,
                    // which is why it reverted every density correction we
                    // wrote: the capture genuinely was being resampled at 99%
                    // while the UI said 100%. Guarding this on
                    // `before != z` skipped it in exactly the broken case, since
                    // the model already equalled the target. So write a
                    // different value first to force the change through, then
                    // the target. Unanimated — a correction, not a motion.
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.magnification = Self.glideSettleNudge(for: z)
                    self.magnification = z
                    CATransaction.commit()
                    self.applyMagnificationFilter(for: z)
                    self.documentView?.needsDisplay = true
                }
            }
        })
    }

    /// Ease into the new size after a move-triggered canvas grow instead of
    /// snapping. Grows the frame, then animates the scroll so the content that
    /// was on screen glides to its resting place (compensating the grow's
    /// `shift`) while the new transparent margin extends the scrollable area. The
    /// canvas is flipped + native, so document-space == image-space: the stable
    /// scroll origin is simply `previousOrigin + shift`. `previousOrigin` is the
    /// clip bounds origin captured BEFORE the grow.
    func animateGrowSettle(shift: CGVector, previousOrigin: NSPoint) {
        applyZoomToCanvasFrame()   // grow the frame now (don't wait for observeZoom)
        applyMagnification()
        layoutSubtreeIfNeeded()
        let target = NSPoint(x: previousOrigin.x + shift.dx, y: previousOrigin.y + shift.dy)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            contentView.animator().setBoundsOrigin(target)
        }
        reflectScrolledClipView(contentView)
    }

    func fitToWindow(animated: Bool = true) {
        limitScrollToFocus = false
        // RAW viewport (not contentView.bounds, which is divided by the current
        // magnification): fit must be measured against actual viewport points.
        let viewport = contentSize
        let imgSize = currentImageSize()
        guard imgSize.width > 0, imgSize.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return }
        state.zoom = Self.clampZoom(
            Self.fitZoom(
                imageSize: imgSize,
                viewportSize: viewport,
                inset: Self.fitInset
            )
        )
        recenterAfterFit(animated: animated)
    }

    /// Re-layout and re-center the image, even when the new zoom equals the old.
    /// The zoom observation only fires on an actual change, so re-clicking a Fit
    /// button after a hand-pan (which offset the scroll without changing zoom)
    /// would otherwise leave the image where the pan left it instead of fitting.
    private func recenterAfterFit(animated: Bool = true) {
        applyZoomToCanvasFrame()        // native size + refresh the focus limit
        guard animated else {
            // Image switches land instantly — a glide on every switch reads as
            // churn, not feedback. (Original snap path.)
            applyMagnification()
            recenterCanvas()
            return
        }
        // ONE native zoom+pan motion via magnify(toFit:) — animating
        // `magnification` and the clip scroll as two parallel implicit
        // animations made mid-flight frames translate separately from the
        // scale (read as the content "sliding" then settling). Feeding the
        // final visible rect (viewport/z, centered on the document, aspect ==
        // viewport) makes magnify(toFit:) land on exactly `z` while AppKit
        // interpolates the whole motion as a single zoom path.
        let z = Self.clampZoom(state.zoom)
        let viewport = contentSize
        guard let doc = documentView, viewport.width > 0, viewport.height > 0, z > 0 else { return }
        let w = viewport.width / z, h = viewport.height / z
        var target = CGRect(x: doc.frame.midX - w / 2, y: doc.frame.midY - h / 2,
                            width: w, height: h)
        // Clamp/center the final origin the same way manual scrolling would so
        // the animation settles without a post-hoc correction. `state.zoom`
        // was already set by the caller; the glide's completion settles the
        // model magnification + crisp filter.
        target.origin = centerClip.constrainBoundsRect(target).origin
        withZoomGlide { animator().magnify(toFit: target) }
    }

    /// Commit a crop smoothly by CROSS-FADING the pre-crop appearance out over
    /// the freshly-cropped canvas. `mutate` applies the crop to `state` (sets
    /// `croppedRect`, clips annotations, clears `pendingCrop`); this then resizes
    /// the document view and re-centers it SYNCHRONOUSLY — no deferred one-frame
    /// snap — while a snapshot of the old view fades away on top.
    ///
    /// The fade uses a SNAPSHOT ghost rather than a `CATransition` on the canvas
    /// layer: the canvas draws via `drawRect`, so AppKit refreshes its backing
    /// store on a later cycle (outside the transaction) and a layer transition
    /// has nothing to cross-fade. Snapshotting the current appearance (magnified
    /// image + settled marquee, both captured from the shared host) and fading it
    /// out works regardless of the redraw timing. Zoom is left as-is.
    func commitCropSmoothly(_ mutate: () -> Void, chrome: NSView?) {
        let duration = Self.cropCommitDuration
        // Snapshot the pre-crop appearance from the host so the ghost includes
        // BOTH the magnified image (this scroll view) and the crop marquee /
        // dimensions label (the sibling chrome overlay), correctly positioned.
        let host = superview
        let ghost: NSImageView? = {
            guard let host, host.bounds.width > 0, host.bounds.height > 0,
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
            else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(rep)
            let view = NSImageView(frame: host.bounds)
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            view.wantsLayer = true
            host.addSubview(view, positioned: .above, relativeTo: nil)
            return view
        }()
        _ = chrome  // captured within the host snapshot above

        suppressCropFrameSync = true
        mutate()                   // croppedRect set → canvas/chrome redraw cropped
        applyZoomToCanvasFrame()   // resize doc view to the cropped size, now
        recenterCanvas()           // center the smaller doc view, now

        guard let ghost else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ghost.animator().alphaValue = 0
        }, completionHandler: { [weak ghost] in ghost?.removeFromSuperview() })
    }

    /// Re-center the (possibly resized) document view inside the viewport at the
    /// current magnification. Shared by the crop-commit settle and fits.
    private func recenterCanvas() {
        let centeredOrigin = centerClip.constrainBoundsRect(
            CGRect(origin: .zero, size: centerClip.bounds.size)).origin
        centerClip.scroll(to: centeredOrigin)
        reflectScrolledClipView(centerClip)
    }

    /// Apply `state.zoom` as the scroll-view magnification (idempotent; preserves
    /// the current scroll centre). Explicit-focal-point zooms call
    /// `setMagnification(_:centeredAt:)` directly instead.
    private func applyMagnification() {
        let z = Self.clampZoom(state.zoom)
        if abs(magnification - z) > 0.0001 { magnification = z }
        applyMagnificationFilter(for: z)
    }

    /// Crisp zoom-in: scroll magnification samples the rasterized document
    /// through the LAYER TREE, and whichever layer actually carries the scale
    /// must use nearest or zoomed captures blend into softness
    /// (screen-measured: glyph cores 39 → 44+ under linear). The exact layer
    /// AppKit scales varies (document/clip/scroll), so pin all three.
    ///
    /// Nearest only at WHOLE multiples, though: `zoomStep` is 1.25 applied
    /// multiplicatively, so most zooms are fractional, and nearest there
    /// duplicates some source pixels and not others — glyph stems thicken
    /// unevenly. See `EditorCanvasView.magnificationFilter(forZoom:)`.
    ///
    /// Minification (<100%) is the other half, and matters more: fit zoom is
    /// where a capture is usually viewed. The layer default is `.linear`, which
    /// samples 2x2 texels — at a fit like 64% that reduces by ~1.56x, so thin
    /// glyph strokes fall between sample points and alias away, thinning and
    /// breaking text. `.trilinear` mipmaps instead: Core Animation pre-filters
    /// smaller levels and blends them, which is what a downscale needs. Costs a
    /// little texture memory for the mip chain.
    func applyMagnificationFilter(for zoom: CGFloat) {
        let filter = EditorCanvasView.magnificationFilter(forZoom: zoom)
        for layer in [documentView?.layer, contentView.layer, self.layer] {
            layer?.magnificationFilter = filter
            layer?.minificationFilter = .trilinear
        }
        // `contentsScale` is deliberately NOT set here: AppKit already keeps it
        // at backing x magnification for a magnified layer-backed scroll view,
        // and overwrites anything set from outside. What the canvas controls is
        // the BLIT density — see `EditorCanvasView.canvasRasterScale`, which
        // computes it rather than reading the layer back.
    }

    /// Zoom to 1:1 on the whole image (leaves focus-scroll mode; keeps the focus
    /// dimming).
    func actualSize() {
        limitScrollToFocus = false
        setZoomPreservingFocalPoint(1.0)
    }

    func fitToWidth() {
        limitScrollToFocus = false
        // Measure the scroll view's OWN bounds, not contentView (the clip view):
        // the clip shrinks when a scroller appears, so measuring it makes the fit
        // non-idempotent (each click computes against a different size). The
        // scroll view's bounds are stable across scroller toggles; the scroller
        // width is reserved separately below.
        let viewport = bounds.size
        let imgSize = currentImageSize()
        guard imgSize.width > 0, viewport.width > 0 else { return }
        state.zoom = Self.fitWidthZoom(
            imageSize: imgSize,
            viewportSize: viewport,
            padding: EditorCanvasView.imagePadding,
            scrollerWidth: reservedScrollerWidth()
        )
        recenterAfterFit()
    }

    func fitToHeight() {
        limitScrollToFocus = false
        let viewport = bounds.size   // stable reference — see fitToWidth.
        let imgSize = currentImageSize()
        guard imgSize.height > 0, viewport.height > 0 else { return }
        state.zoom = Self.fitHeightZoom(
            imageSize: imgSize,
            viewportSize: viewport,
            padding: EditorCanvasView.imagePadding,
            scrollerWidth: reservedScrollerWidth()
        )
        recenterAfterFit()
    }

    /// Zoom + scroll so `rect` (visible-image coords) fills the viewport. This is
    /// the Focus button's path — it enters focus-scroll mode.
    func fit(imageRect rect: CGRect) {
        limitScrollToFocus = true
        // RAW viewport for the fit math (contentView.bounds is divided by the
        // current magnification).
        let viewport = contentSize
        guard rect.width > 0, rect.height > 0,
              viewport.width > 0, viewport.height > 0 else { return }
        let availW = max(0, viewport.width - Self.fitInset * 2)
        let availH = max(0, viewport.height - Self.fitInset * 2)
        // Fill only part of the viewport so a draggable margin remains around
        // the focus rect (see `focusViewportFill`).
        let z = Self.clampZoom(min(availW / rect.width, availH / rect.height) * Self.focusViewportFill)
        state.zoom = z
        applyZoomToCanvasFrame()   // native; refreshes the focus limit
        applyMagnification()        // apply z as a GPU magnification
        // Scroll so the focus rect centre sits at the viewport centre. The
        // document is native, so `rect`'s canvas position is `rect + pad`; the
        // clip's bounds (document coords) are `contentSize / z`.
        let pad = EditorCanvasView.imagePadding
        let clip = contentView.bounds.size
        let target = NSPoint(x: rect.midX + pad - clip.width / 2,
                             y: rect.midY + pad - clip.height / 2)
        updateFocusScrollLimit()
        contentView.scroll(to: target)
        reflectScrolledClipView(contentView)
    }

    /// While a focus is set, constrain scrolling so the viewport CENTER can only
    /// range over the focus rect — i.e. the scrollbar follows the focus area.
    /// Recomputed on every zoom/frame change so it stays in canvas coords.
    private func updateFocusScrollLimit() {
        guard limitScrollToFocus, let focus = state.focusRect else { centerClip.focusLimit = nil; return }
        let pad = EditorCanvasView.imagePadding
        // NATIVE document coords (no × zoom — magnification scales the display):
        // the focus region in the canvas's native space is the scrollable content
        // while focused. The scrollers (via documentRect) and the scroll clamp
        // both use it, so they ignore the rest of the image.
        centerClip.focusLimit = CGRect(x: focus.minX + pad, y: focus.minY + pad,
                                       width: focus.width, height: focus.height)
    }

    /// Hand-tool focus pan: move the focus and scroll the clip by the SAME
    /// translation (`Δfocus · zoom`), so the brackets stay fixed on screen while
    /// the image slides beneath them. Incremental — it continues from the current
    /// scroll position rather than re-centering, so there's no jump (incl. after a
    /// Fit), and it doesn't force the focus-scroll mode or resize the canvas frame
    /// (zoom and image size are unchanged), which avoids glitching. The async
    /// re-fit is suppressed so the moved focus doesn't reset zoom.
    func setFocusDuringPan(_ newFocus: CGRect) {
        guard let old = state.focusRect else { return }
        suppressFocusRefit = true
        state.focusRect = newFocus
        updateFocusScrollLimit()   // focus-mode scroll limit tracks the moved focus
        // Native document coords (magnification handles display scaling): the
        // clip origin shifts by the SAME translation the focus moved, keeping the
        // brackets fixed on screen while the image slides beneath them.
        let dx = newFocus.minX - old.minX
        let dy = newFocus.minY - old.minY
        var origin = contentView.bounds.origin
        origin.x += dx
        origin.y += dy
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    /// End a hand-tool focus pan. Re-enable re-fit for FUTURE focus changes, but
    /// not now — keep the user's current zoom and panned position. Deferred to the
    /// next run-loop so any `observeFocus` tasks queued during the drag (which see
    /// the flag still set) skip their re-fit before the flag clears.
    func endFocusPan() {
        DispatchQueue.main.async { [weak self] in self?.suppressFocusRefit = false }
    }

    /// Fit the current focus rect if one is set, otherwise fit the whole image.
    func fitFocusOrWindow(animated: Bool = true) {
        if suppressFocusRefit { return }
        if let focus = state.focusRect {
            fit(imageRect: focus)
        } else {
            fitToWindow(animated: animated)
        }
    }

    /// Zoom applied when an image is freshly loaded or switched in. Honors the
    /// user's remembered zoom (so switching images and relaunching keep it),
    /// falling back to fit when nothing's remembered yet. Distinct from the
    /// user-facing Fit/Focus buttons, which always recompute a true fit.
    ///
    /// `fitFresh` forces a fit regardless of the remembered zoom — used for a
    /// newly captured/created image so it always lands fitted to the viewport.
    func applyInitialZoom(fitFresh: Bool = false) {
        if !fitFresh, let remembered = ImageZoomMemory.load(for: state.sourceURL) {
            state.zoom = Self.clampZoom(remembered)
            // Center like the fit path does. fitFocusOrWindow() routes through
            // recenterAfterFit (which re-centers the clip), but the
            // remembered-zoom branch skipped it — so an image smaller than the
            // viewport stayed pinned to the edge until the first scroll. It also
            // sizes the canvas frame, so the first paint is at the right scale.
            // Unanimated: image switches should land instantly, not glide.
            recenterAfterFit(animated: false)
        } else {
            fitFocusOrWindow(animated: false)
            // Size the canvas frame NOW rather than waiting for the async zoom
            // observation, so the image's first paint is already at the right
            // scale (otherwise it flashes at the previous scale for one frame).
            applyZoomToCanvasFrame()
        }
    }

    // MARK: - Pure math (exposed for tests)

    /// How close to 100% counts as 100%.
    ///
    /// 100% is the only zoom that shows a byte-exact copy of the capture — the
    /// blit draws 1:1 and the interpolation is nearest, so nothing is resampled.
    /// A percent either side loses that, and the difference is visible on text.
    /// Tight enough that the neighbouring real zoom steps (0.8 and 1.25, from
    /// the 1.25 multiplier) are nowhere near being swallowed.
    nonisolated static let unitySnapTolerance: CGFloat = 0.02

    /// Clamp for manual zoom (buttons / typed input): floor at `minZoom`,
    /// ceiling at `manualMaxZoom`. Auto-fit is bounded separately by
    /// `fitMaxZoom` inside `fitZoom`.
    ///
    /// Also makes 100% magnetic. An upward glide can land a hair short and stay
    /// there — a trace of 70% -> 100% finished with the model reading 1.0000
    /// while the scroll view sat at 0.9900, so the picture was a 1% resample of
    /// itself while the UI claimed 100%. Snapping is more robust than depending
    /// on an animation to land exactly, and it makes the crisp path reachable
    /// from a fit that happens to fall near 100% too.
    nonisolated static func clampZoom(_ z: CGFloat) -> CGFloat {
        let bounded = max(minZoom, min(manualMaxZoom, z))
        return abs(bounded - 1) <= unitySnapTolerance ? 1 : bounded
    }

    /// A magnification a hair off `z`, used to force an assignment through.
    ///
    /// `animator().setMagnification` sets the model property to its target at
    /// once and animates the APPLIED value, and the applied value can stop
    /// short. Re-assigning the target is then a no-op precisely when it matters,
    /// because the model already holds it — so settling has to write a different
    /// value first. Nudges downward, flipping upward at the floor so the result
    /// is always a magnification the scroll view will accept unclamped.
    nonisolated static func glideSettleNudge(for z: CGFloat) -> CGFloat {
        let delta: CGFloat = 0.001
        return z - delta >= minZoom ? z - delta : z + delta
    }

    /// Continuous zoom factor for a ⌘+scroll gesture: multiply `current` by
    /// `exp(scrollDeltaY * sensitivity)` (symmetric in/out) and clamp. A notched
    /// wheel (`precise == false`) gets a higher per-unit sensitivity than a
    /// precise trackpad (whose deltas are far larger) so both feel comparable.
    /// Positive `scrollDeltaY` zooms in.
    nonisolated static func zoomByScroll(_ current: CGFloat, scrollDeltaY: CGFloat,
                                         precise: Bool) -> CGFloat {
        let sensitivity: CGFloat = precise ? 0.002 : 0.035
        return clampZoom(current * exp(scrollDeltaY * sensitivity))
    }

    /// Apply a ⌘+scroll zoom anchored at `winPoint` (window space) so the point
    /// under the cursor stays put. Mirrors `setZoomPreservingFocalPoint`'s state
    /// update but anchors at the cursor instead of the viewport centre.
    func zoomByScroll(scrollDeltaY: CGFloat, precise: Bool, atWindowPoint winPoint: NSPoint) {
        let newZoom = Self.zoomByScroll(state.zoom, scrollDeltaY: scrollDeltaY, precise: precise)
        guard abs(newZoom - state.zoom) > 0.0001 else { return }
        state.checkpointZoomIfNeeded()   // user gesture; coalesced per burst
        state.zoom = newZoom
        // `setMagnification(_:centeredAt:)` wants the anchor "in content view
        // space" (the clip view — document coordinates under magnification),
        // NOT scroll-view frame space; the wrong space made ⌘+scroll appear to
        // zoom about a fixed point instead of the cursor.
        setMagnification(newZoom, centeredAt: contentView.convert(winPoint, from: nil))
    }

    /// Fit zoom for a single OBJECT (double-clicked image object): unlike the
    /// whole-image `fitZoom`, this may zoom IN past 100% so a small object can
    /// fill the viewport — bounded by the same manual zoom ceiling.
    nonisolated static func objectFitZoom(objectSize: CGSize, viewportSize: CGSize,
                                          inset: CGFloat) -> CGFloat {
        guard objectSize.width > 0, objectSize.height > 0 else { return 1 }
        let availableW = max(1, viewportSize.width - inset * 2)
        let availableH = max(1, viewportSize.height - inset * 2)
        return clampZoom(min(availableW / objectSize.width, availableH / objectSize.height))
    }

    /// Zoom + scroll so `r` (documentView coordinates) fills the viewport,
    /// centered. Used by double-clicking an image object on the canvas. A ⌘Z
    /// step via the same coalesced zoom checkpoint as every other zoom gesture.
    func zoomToFitDocumentRect(_ r: CGRect) {
        let viewport = contentSize
        guard r.width > 0, r.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        state.checkpointZoomIfNeeded()
        applyZoomToCanvasFrame()
        // `magnifyToFitRect` animates zoom AND position in one native call
        // (clamped by min/maxMagnification, which mirror our zoom limits).
        // Inflate the object rect so the standard fit inset survives at the
        // TARGET zoom: inset viewport points = inset/z document units.
        let z = Self.objectFitZoom(objectSize: r.size, viewportSize: viewport,
                                   inset: Self.fitInset)
        let insetDoc = Self.fitInset / z
        state.zoom = z   // the animation lands here; never read magnification back
        withZoomGlide { animator().magnify(toFit: r.insetBy(dx: -insetDoc, dy: -insetDoc)) }
    }

    /// Zoom to apply when a fresh image loads or is switched in: the user's
    /// remembered zoom when one exists, otherwise the computed fit. Pure so it's
    /// unit-testable.
    nonisolated static func initialZoom(remembered: CGFloat?, fit: CGFloat) -> CGFloat {
        if let remembered { return clampZoom(remembered) }
        return fit
    }

    static func fitZoom(
        imageSize: CGSize,
        viewportSize: CGSize,
        inset: CGFloat
    ) -> CGFloat {
        let availableW = max(0, viewportSize.width - inset * 2)
        let availableH = max(0, viewportSize.height - inset * 2)
        let sx = availableW / imageSize.width
        let sy = availableH / imageSize.height
        return min(sx, sy, fitMaxZoom)
    }

    /// The zoomed DOCUMENT is `(image + 2·padding) × zoom` — zoom is a
    /// magnification transform, so the `imagePadding` border scales with it.
    /// The fit must therefore solve for the whole document spanning the
    /// viewport, or the document overflows by `2·padding·(z−1)` whenever the
    /// fit upscales — leaving a scrollbar that scrolls a few pixels. The 0.5pt
    /// safety keeps float rounding from tipping the document past the clip.
    private static let fitSafety: CGFloat = 0.5

    /// Zoom so the zoomed document (image + its padding border) spans the full
    /// viewport width. Unlike `fitZoom` (whole-image fit, capped at 100%),
    /// fit-width is an explicit action and upscales low-res images up to
    /// `manualMaxZoom` — matching focus-fit.
    static func fitWidthZoom(
        imageWidth: CGFloat,
        viewportWidth: CGFloat,
        padding: CGFloat
    ) -> CGFloat {
        let doc = imageWidth + padding * 2
        guard doc > 0 else { return 1 }
        return clampZoom(max(0, viewportWidth - fitSafety) / doc)
    }

    /// Zoom so the zoomed document spans the full viewport height. See `fitWidthZoom`.
    static func fitHeightZoom(
        imageHeight: CGFloat,
        viewportHeight: CGFloat,
        padding: CGFloat
    ) -> CGFloat {
        let doc = imageHeight + padding * 2
        guard doc > 0 else { return 1 }
        return clampZoom(max(0, viewportHeight - fitSafety) / doc)
    }

    /// Fit-to-width that reserves the vertical scroller's width when the result
    /// is taller than the viewport. Otherwise, on legacy-scroller setups the
    /// scroller appears *after* the canvas resizes, shrinks the clip view, and
    /// the document (which spans the viewport width) overflows — so the fit
    /// needs a second click. `scrollerWidth` is 0 for overlay scrollers, which
    /// float and claim no layout width.
    static func fitWidthZoom(
        imageSize: CGSize,
        viewportSize: CGSize,
        padding: CGFloat,
        scrollerWidth: CGFloat
    ) -> CGFloat {
        let z0 = fitWidthZoom(imageWidth: imageSize.width, viewportWidth: viewportSize.width, padding: padding)
        let overflowsVertically = (imageSize.height + padding * 2) * z0 > viewportSize.height
        guard overflowsVertically else { return z0 }
        return fitWidthZoom(imageWidth: imageSize.width,
                            viewportWidth: viewportSize.width - scrollerWidth, padding: padding)
    }

    /// Fit-to-height that reserves the horizontal scroller's width when the
    /// result is wider than the viewport. See `fitWidthZoom(imageSize:…)`.
    static func fitHeightZoom(
        imageSize: CGSize,
        viewportSize: CGSize,
        padding: CGFloat,
        scrollerWidth: CGFloat
    ) -> CGFloat {
        let z0 = fitHeightZoom(imageHeight: imageSize.height, viewportHeight: viewportSize.height, padding: padding)
        let overflowsHorizontally = (imageSize.width + padding * 2) * z0 > viewportSize.width
        guard overflowsHorizontally else { return z0 }
        return fitHeightZoom(imageHeight: imageSize.height,
                             viewportHeight: viewportSize.height - scrollerWidth, padding: padding)
    }

    /// Width a *visible* scroller claims from the content area. Overlay
    /// scrollers float (0); legacy scrollers reduce the clip view, so fit-to-
    /// width/height must reserve it to settle in a single click.
    private func reservedScrollerWidth() -> CGFloat {
        guard scrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    // MARK: - Observation

    private func observeZoom() {
        withObservationTracking {
            _ = state.zoom
            _ = state.croppedRect   // crop changes the visible image size
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.suppressCropFrameSync {
                    // A crop commit already resized + re-centered the frame
                    // synchronously (and animated it). Skip the deferred snap
                    // for this one firing so the two don't fight.
                    self.suppressCropFrameSync = false
                } else if self.zoomGlideInFlight {
                    // An animated zoom glide is driving the visuals; a snap
                    // here would cancel it mid-flight. The glide's completion
                    // runs applyMagnification (and clears the flag).
                } else {
                    self.applyZoomToCanvasFrame()   // native; resizes only on crop change
                    self.applyMagnification()        // apply zoom as a GPU magnification
                }
                // Remember the user's zoom from ANY source — slider, ±, and the
                // Fit/Fit-width/Fit-height buttons — PER capture, so each image
                // keeps its own zoom across switches/relaunch without bleeding
                // into others. Applies whether or not a focus crop is present.
                ImageZoomMemory.store(self.state.zoom, for: self.state.sourceURL)
                self.observeZoom()
            }
        }
    }

    private func observeFocus() {
        withObservationTracking {
            _ = state.focusRect
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.fitFocusOrWindow()
                self?.observeFocus()
            }
        }
    }

    private func applyZoomToCanvasFrame() {
        let size = currentImageSize()
        // Reserve a blank border of `imagePadding` on every side so anchor dots
        // on the image boundary still have real canvas (and thus mouse events)
        // around them. `EditorCanvasView.currentScale()` backs this out.
        let pad = EditorCanvasView.imagePadding
        // NATIVE size: zoom is applied as magnification, not a frame resize, so
        // the document view (and its layer backing store) never grows with zoom.
        let newFrame = CGRect(
            x: 0, y: 0,
            width: size.width + pad * 2,
            height: size.height + pad * 2
        )
        // Recompute the focus limit (in canvas coords, which scale with zoom)
        // BEFORE resizing the frame: setting the frame re-runs the clip's
        // constrainBoundsRect, which must see the current limit. In particular
        // when a whole-image fit just left focus-scroll mode, the limit must be
        // cleared here first, or the clip clamps to the stale focus region and
        // the position only corrects (jumps) on the next scroll.
        updateFocusScrollLimit()
        canvas.frame = newFrame
        canvas.needsDisplay = true
    }

    private func currentImageSize() -> CGSize {
        if let crop = state.croppedRect { return crop.size }
        return CGSize(width: state.sourceImage.width, height: state.sourceImage.height)
    }
}

/// NSClipView that recenters the documentView on whichever axis is smaller
/// than the viewport, instead of the default bottom-left pinning. When
/// `focusLimit` is set (focus mode), it instead constrains scrolling to that
/// canvas-space region so the scrollbar only pans within the focus area.
private final class CenteringClipView: NSClipView {
    /// The focus region in canvas coords. When set (focus mode), it becomes the
    /// scrollable content: scrollers size to it and scrolling is clamped to it,
    /// while the documentView keeps drawing the whole image + dimming.
    /// nil = normal full-image behavior.
    var focusLimit: NSRect? {
        didSet { if focusLimit != oldValue { scrollToVisible(bounds) } }
    }

    /// Drives the scrollers off the focus region while focused (so they hide when
    /// it fits and size to it when zoomed past the viewport), instead of the
    /// whole image. On an axis where the focus is SMALLER than the viewport, we
    /// report the viewport size (centered on the focus) so the scroller hides and
    /// AppKit doesn't try to align the visible rect to the focus origin — that
    /// alignment fought the centering clamp and made the focus snap/jump.
    override var documentRect: NSRect {
        guard let limit = focusLimit else { return super.documentRect }
        var r = limit
        let v = bounds.size
        if r.width < v.width { r.origin.x -= (v.width - r.width) / 2; r.size.width = v.width }
        if r.height < v.height { r.origin.y -= (v.height - r.height) / 2; r.size.height = v.height }
        return r
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let limit = focusLimit {
            rect.origin.x = Self.clamp(rect.origin.x, size: rect.width, lo: limit.minX, hi: limit.maxX)
            rect.origin.y = Self.clamp(rect.origin.y, size: rect.height, lo: limit.minY, hi: limit.maxY)
            return rect
        }
        guard let documentView = documentView else { return rect }
        let docFrame = documentView.frame
        if docFrame.width < rect.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if docFrame.height < rect.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }

    /// Right-clicks in the gray margin around a centered/zoomed-out canvas land
    /// on the clip view, not the (smaller) document view — so the canvas's own
    /// `menu(for:)` never fires and no context menu appeared out there. Forward
    /// to the canvas so the same menu is available anywhere in the viewport. The
    /// canvas computes its point from `event.locationInWindow`, so it hit-tests
    /// correctly even though the clip view received the click; in the margin the
    /// point maps outside every annotation, yielding the empty-area capture menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        (documentView as? EditorCanvasView)?.menu(for: event) ?? super.menu(for: event)
    }

    /// Left-clicks in that same margin land here too, so clicking away from the
    /// image used to leave the selection untouched — unlike clicking empty
    /// canvas, which clears it — and a rubber-band selection could not be
    /// started from out here at all.
    ///
    /// The canvas decides what to do with the click and tells us whether it
    /// took the drag. When it has (Select tool), we forward the rest of the
    /// sequence to it: a drag belongs to the view that received `mouseDown`,
    /// so without this the canvas would start a marquee and never be told it
    /// ended.
    private var forwardingDragToCanvas = false

    override func mouseDown(with event: NSEvent) {
        guard let canvas = documentView as? EditorCanvasView else {
            super.mouseDown(with: event)
            return
        }
        forwardingDragToCanvas = canvas.handleMarginMouseDown(event)
        if !forwardingDragToCanvas { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard forwardingDragToCanvas, let canvas = documentView as? EditorCanvasView else {
            super.mouseDragged(with: event)
            return
        }
        canvas.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard forwardingDragToCanvas, let canvas = documentView as? EditorCanvasView else {
            super.mouseUp(with: event)
            return
        }
        forwardingDragToCanvas = false
        canvas.mouseUp(with: event)
    }

    /// Keep a `size`-wide viewport within `[lo, hi]`; if that span is narrower
    /// than the viewport, center the viewport on it.
    private static func clamp(_ origin: CGFloat, size: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        let maxOrigin = hi - size
        if maxOrigin < lo { return (lo + hi) / 2 - size / 2 }
        return min(max(origin, lo), maxOrigin)
    }
}
