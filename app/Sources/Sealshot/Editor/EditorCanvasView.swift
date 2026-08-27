import AppKit
import Observation
import UniformTypeIdentifiers

/// Style for a newly drawn closed shape (rectangle/ellipse): the current
/// stroke defaults plus the tool's default fill (`shapeFillColor`; nil = no
/// fill). Free function so the creation style is unit-testable without a view.
@MainActor
func shapeCreationStyle(state: EditorState) -> Style {
    Style(strokeColor: SerializableColor(state.selectedColor),
          strokeWidth: state.strokeWidth,
          opacity: state.creationOpacity,
          fillColor: state.shapeFillColor.map { SerializableColor(opaqueSRGB($0)) },
          cornerRadius: state.shapeCornerRadius,
          shadow: state.shadowDefault(for: state.selectedTool),
          outlineColor: state.selectedOutlineColor.map { SerializableColor(opaqueSRGB($0)) },
          outlineWidth: state.outlineWidth)
}

/// Style for a newly drawn stroke-only annotation (arrow/line): current stroke
/// color + width + the shared creation opacity. Mirrors the arrow/line object
/// panel (stroke color, stroke width, opacity).
@MainActor
func strokeCreationStyle(state: EditorState) -> Style {
    // Arrowheads belong to arrows only; the shaft dash applies to whichever
    // stroke tool is active (Line carries it too; Pen ignores it at render).
    let isArrowLike = state.selectedTool == .arrow || state.selectedTool == .penArrow
    return Style(strokeColor: SerializableColor(state.selectedColor),
                 strokeWidth: state.strokeWidth,
                 opacity: state.creationOpacity,
                 startCap: isArrowLike ? state.arrowStartCap : .none,
                 endCap: isArrowLike ? state.arrowEndCap : .none,
                 dashStyle: state.dashStyle,
                 // Straight arrows only: freehand arrows always render a
                 // uniform stroke (user rule), so they never carry tapered.
                 shaftStyle: state.selectedTool == .arrow ? state.arrowShaftStyle : .uniform,
                 shadow: state.shadowDefault(for: state.selectedTool),
                 outlineColor: state.selectedOutlineColor.map { SerializableColor(opaqueSRGB($0)) },
                 outlineWidth: state.outlineWidth)
}

/// Style for a newly placed numbered badge: fill + number (stroke) colors and
/// the shared creation opacity. Mirrors the badge object panel.
@MainActor
func badgeCreationStyle(state: EditorState) -> Style {
    Style(strokeColor: SerializableColor(opaqueSRGB(state.badgeNumberColor)),
          strokeWidth: 0,
          opacity: state.creationOpacity,
          fillColor: SerializableColor(opaqueSRGB(state.badgeFillColor)),
          shadow: state.shadowDefault(for: state.selectedTool),
          outlineColor: state.selectedOutlineColor.map { SerializableColor(opaqueSRGB($0)) },
          outlineWidth: state.outlineWidth)
}

/// Style for a newly created text box: text color, opacity, and font/bold
/// seeds. Committed text is re-styled via the inline editor; the object panel
/// exposes opacity (mirrored here).
@MainActor
func textCreationStyle(state: EditorState) -> Style {
    Style(strokeColor: SerializableColor(state.selectedColor),
          strokeWidth: 0,
          opacity: state.creationOpacity,
          fontSize: state.textFontSize,
          isBold: state.textIsBold,
          shadow: state.shadowDefault(for: state.selectedTool),
          textAlignment: state.textAlignment,
          textVerticalAlignment: state.textVerticalAlignment,
          lineSpacing: state.textLineSpacing)
}

/// Style for a newly drawn blur region: the tool's current blur mode +
/// strength. Stroke/fill are unused by blur; opacity stays 1 so the redaction
/// is fully opaque.
@MainActor
func blurCreationStyle(state: EditorState) -> Style {
    Style(strokeColor: SerializableColor(state.selectedColor),
          strokeWidth: 0,
          opacity: 1.0,
          // fillColor carries the Solid effect's color (ignored by the others).
          fillColor: SerializableColor(opaqueSRGB(state.blurSolidColor)),
          blurMode: state.blurMode,
          // Solid reinterprets blurStrength as fill opacity; use the dedicated
          // Solid-opacity default (fully opaque) instead of the Gaussian strength.
          blurStrength: state.blurMode == .solid ? state.blurSolidOpacity : state.blurStrength)
}

/// Renders the source image plus annotations plus any in-progress drawing.
/// Translates mouse events from view-space to image-space coordinates so
/// `EditorState.annotations` is independent of window resizing.
final class EditorCanvasView: NSView {

    private let state: EditorState

    /// Fired at the start of any user mouse-down on the canvas. The controller
    /// uses it to mark the canvas (not the strip) as the active surface for ⌘A.
    var onUserMouseDown: (() -> Void)?

    /// Fired after an annotation settles — an object-move drag finishes, a
    /// freshly drawn annotation is committed, or a text box commits. The
    /// controller grows the image to fit any annotation now past the edge
    /// ("expand canvas to fit").
    var onAnnotationSettled: (() -> Void)?

    /// In-progress shape being drawn by the current mouseDown→mouseDragged
    /// chain. Image-space coordinates. Reset on mouseUp.
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    /// Accumulated freehand path (image space) while the pen tool is dragging.
    private var penPoints: [CGPoint] = []

    /// A freehand pen / free-arrow whose on-screen bounding box is smaller than
    /// this (in screen points) is treated as a click (no stroke committed,
    /// selection cleared) rather than a stray dot. Uses the bounding box — not
    /// cumulative travel — so a click that jitters back and forth in one spot is
    /// still recognized as a click.
    private let penClickThreshold: CGFloat = 6

    /// Arrow/line drags shorter than this (in screen points, base scale — same
    /// convention as `penClickThreshold`) are treated as a click and draw
    /// nothing, so an accidental micro-drag doesn't leave a stray arrow/line.
    private let minArrowDragDistance: CGFloat = 6

    /// On-screen bounding-box diagonal of an image-space path, in screen points.
    private func penPathScreenExtent(_ pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return 0 }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return hypot(maxX - minX, maxY - minY) * currentScale()
    }

    /// True on-screen distance of the current mouseDown→mouseUp drag, in window
    /// points — zoom-independent (window coords ignore scroll magnification,
    /// unlike image length × base scale). With no recorded down point, returns a
    /// huge value so nothing is committed.
    private func screenDragDistance(event: NSEvent) -> CGFloat {
        guard let down = mouseDownWindowPoint else { return .greatestFiniteMagnitude }
        let up = event.locationInWindow
        return hypot(up.x - down.x, up.y - down.y)
    }

    /// Interaction mode driven by `mouseDown` and consumed by
    /// `mouseDragged`. `.idle` means we're not actively interacting.
    private enum InteractionMode {
        case idle
        case drawing                       // 3.A drawing flow (arrow/rect/crop)
        case moving(originals: [UUID: Geometry])
        case resizing(handle: AnnotationHandle, originalGeometry: Geometry)
        case rotating(annotationID: UUID, center: CGPoint,
                      startAngle: CGFloat, startTransform: AnnotationTransform)
        case marquee                       // rubber-band select (Select tool)
        case focusCropping(handle: FocusHandle, startRect: CGRect)
        case cropResizing(handle: FocusHandle, startRect: CGRect)  // adjust pending crop edge/corner
        case cropMoving(startRect: CGRect, grab: CGPoint)          // drag pending crop interior
        case imagePanning(lastWin: CGPoint, startFocus: CGRect?, isEdit: Bool)  // Hand tool / right-drag; lastWin = window space
    }

    private var interactionMode: InteractionMode = .idle {
        // Mirror onto the state so observers doing heavy work (autosave,
        // strip-preview composite, sidebar rebuild) can hold off until the
        // mouse interaction ends — their debounces would otherwise fire
        // mid-drag whenever the pointer pauses, hitching the drag.
        didSet {
            let active = if case .idle = interactionMode { false } else { true }
            if state.interactionInProgress != active {
                state.interactionInProgress = active
            }
        }
    }
    private var dragStartImagePoint: CGPoint?

    /// Mouse-down location in WINDOW points, so the arrow/line minimum-drag
    /// check can measure a true on-screen distance (zoom-independent). Window
    /// coordinates are unaffected by scroll-view magnification, unlike
    /// image-space length × base scale.
    private var mouseDownWindowPoint: CGPoint?

    /// Rubber-band selection rect endpoints (image space) while marqueeing.
    private var marqueeStart: CGPoint?
    private var marqueeCurrent: CGPoint?

    // MARK: OCR state shared by Live Text and Find in Image. `layout` is cached
    // and invalidated when the displayed base image changes.
    private let textRecognizer = TextRecognizer()
    private let barcodeRecognizer = BarcodeRecognizer()
    /// QR/barcodes detected in the current image while Live Text is active.
    private var ocrBarcodes: [DetectedBarcode] = []
    private var ocrLayout: RecognizedTextLayout?
    private var ocrSelection = TextSelection.collapsed(at: TextPosition(line: 0, char: 0))
    /// Normalized point where the current Live Text drag began, so the drag can
    /// build a character-inclusive selection from press to release.
    private var ocrDragAnchor: CGPoint?
    private var ocrTask: Task<Void, Never>?
    private var barcodeTask: Task<Void, Never>?
    private var isRecognizing = false
    /// The image identity (base + crop) the cached layout was computed for, so
    /// we know when to recompute.
    private var ocrSourceKey: String?
    /// Separate from the text key because Find in Image deliberately skips the
    /// more expensive barcode pass. Entering Live Text after Find can then run
    /// only the missing barcode recognition without repeating OCR.
    private var barcodeSourceKey: String?
    private var imageTextSearchMatches: [ImageTextSearchMatch] = []
    private var activeImageTextSearchMatch = 0
    private var imageTextSearchRequestKey: String?

    /// When true, the hover handlers yield the arrow cursor instead of the
    /// crosshair/tool cursors. Set while a modal overlay (e.g. the enhancing
    /// progress view) covers the canvas — its own tracking area keeps firing
    /// underneath the overlay, so without this it would fight the overlay for
    /// the cursor and show a crosshair over the Cancel button.
    var suppressHoverCursor = false {
        didSet { if suppressHoverCursor { NSCursor.arrow.set() } }
    }

    /// Last known pointer position in image space, used to anchor pastes.
    /// `nil` when the pointer is outside the view.
    private(set) var lastMouseImagePoint: CGPoint?

    /// Called by `SelectionChromeOverlay.mouseExited` so the paste anchor is
    /// cleared when the pointer leaves the viewport (mirrors the old canvas
    /// `mouseExited` that wrote `nil` directly).
    func clearLastMousePoint() { lastMouseImagePoint = nil }

    /// Pre-drag focus, captured so a whole hand-pan commits as one undo step.
    private var panStartFocus: CGRect?

    // Focus/crop DRAWING + anchor hit-test/drag + hover cursors all moved to
    // SelectionChromeOverlay (the non-magnified overlay owns chrome + cursors).

    /// Blank margin (view space) the canvas reserves around the image on every
    /// side. It makes the document view slightly larger than the image so that
    /// anchor dots sitting on the image boundary still have real, event-
    /// receiving canvas around them — otherwise the outer half of a boundary
    /// dot's grab disc would fall in dead clip-view margin and be unhittable.
    /// Kept equal to `fitInset` so a fit-to-window image still shows the same
    /// border, just made of canvas instead of empty viewport.
    static let imagePadding: CGFloat = 16

    /// The inline text editor while a text box is being typed; nil otherwise.
    private var inlineEditor: InlineTextEditor?
    /// Image-space rect of the box currently being edited (created or re-edited).
    private var editingBoxRect: CGRect?
    /// Style used for the box being edited.
    private var editingStyle: Style?
    /// Intrinsic wrap width of the box being edited (image space). Starts as
    /// the box width (or the stored textLayoutWidth when re-editing a
    /// decoupled box) and grows via TextBoxSizer.
    private var editingLayoutWidth: CGFloat = 0
    /// False when the box was manually shrunk (mask ≠ layout): typing then
    /// grows the layout only, never the mask.
    private var editingRectFollowsWidth = true
    // editingAnnotationID promoted to EditorState so SelectionChromeOverlay can observe it.
    /// Runs the editor was seeded with (image space). Applied on first configure only.
    private var editingSeedRuns: [TextRun] = []
    /// Guards against re-seeding the editor on reposition (which would reset styling).
    private var didSeedEditor = false

    override var isFlipped: Bool { true }   // top-left origin matches image-space

    init(state: EditorState) {
        self.state = state
        let imgW = CGFloat(state.sourceImage.width)
        let imgH = CGFloat(state.sourceImage.height)
        super.init(frame: NSRect(x: 0, y: 0, width: imgW, height: imgH))
        // Crisp zoom-IN: the scroll view's magnification scales this view's
        // layer backing store on the GPU, and the LAYER's filter decides how
        // those pixels are sampled. Linear (the default) blends neighbors —
        // zoomed screenshots of text look soft, unlike Snagit/Shottr which
        // pixel-double. Nearest keeps every capture pixel a hard block when
        // magnifying; minification (<100%) keeps the smooth trilinear default.
        //
        // Only at WHOLE multiples, though — see `magnificationFilter(forZoom:)`.
        // Re-applied whenever the zoom changes.
        wantsLayer = true
        applyMagnificationFilter()
        // Without this, `draggingEntered`/`performDragOperation` below are dead
        // code: AppKit only sends dragging messages to a view that has
        // registered. They shipped unregistered, so dropping an image onto a
        // canvas that already had one silently did nothing — the empty-state
        // canvas worked only because `EmptyCanvasView` registers in its own init.
        registerForDraggedTypes([.fileURL])
        // Re-render whenever observable state changes
        startObservingState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: Redaction spotlight scrim
    // The scrim has its own show-intent, stickiness, and fade so sweeping the
    // review list never flashes the canvas: it APPEARS only after the cursor
    // rests on a row, stays up (hole retargeting instantly) while the hover
    // moves between rows, and fades out only after the hover has been gone
    // for a grace period. The instant per-row feedback (yellow highlight on
    // the region, tinted row background) is unaffected.

    /// Proposal whose rects are punched out of the scrim (sticky — survives
    /// the gaps between rows while `redactionFocusID` flickers to nil).
    private var spotlightProposalID: UUID?
    /// Current and target scrim alpha; `spotlightFadeTask` chases the target.
    private var spotlightAlpha: CGFloat = 0
    private var spotlightTargetAlpha: CGFloat = 0
    private var spotlightFadeTask: Task<Void, Never>?
    private var spotlightShowTask: Task<Void, Never>?
    private var spotlightHideTask: Task<Void, Never>?
    private let spotlightMaxAlpha: CGFloat = 0.20
    private var spotlightClipObserver: NSObjectProtocol?

    /// While the scrim is up, copy-on-scroll shifts pre-scrim pixels into
    /// view — an undimmed "torn strip" at the leading edge of any scroll
    /// (the auto-glide or a user scroll). Repaint on every clip-bounds
    /// change while dimmed so the exposed band is drawn under the scrim.
    /// Zero cost when no scrim is showing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Layer backing can be re-created on window moves — re-apply the
        // magnification filter for the CURRENT zoom (see init).
        applyMagnificationFilter()
        if let spotlightClipObserver {
            NotificationCenter.default.removeObserver(spotlightClipObserver)
            self.spotlightClipObserver = nil
        }
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        spotlightClipObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.spotlightAlpha > 0.005 else { return }
                self.needsDisplay = true
            }
        }
    }

    deinit {
        if let spotlightClipObserver {
            NotificationCenter.default.removeObserver(spotlightClipObserver)
        }
    }

    private func updateRedactionSpotlight() {
        guard case .found = state.redactionScan else {
            // Scan ended (applied/cancelled) — drop the scrim immediately.
            spotlightShowTask?.cancel(); spotlightShowTask = nil
            spotlightHideTask?.cancel(); spotlightHideTask = nil
            fadeSpotlight(to: 0)
            return
        }
        if let id = state.redactionFocusID {
            spotlightHideTask?.cancel(); spotlightHideTask = nil
            if spotlightTargetAlpha > 0 {
                // Scrim already up (or fading in) — retarget the hole only.
                if spotlightProposalID != id { spotlightProposalID = id; needsDisplay = true }
            } else {
                // Show intent: only dim once the cursor RESTS on a row.
                spotlightShowTask?.cancel()
                spotlightShowTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.spotlightShowTask = nil
                    guard let current = self.state.redactionFocusID else { return }
                    self.spotlightProposalID = current
                    self.fadeSpotlight(to: self.spotlightMaxAlpha)
                }
            }
        } else {
            spotlightShowTask?.cancel(); spotlightShowTask = nil
            guard spotlightTargetAlpha > 0, spotlightHideTask == nil else { return }
            // Grace: linger briefly so hopping to the next row keeps the
            // scrim up; fade out only when the hover is really gone.
            spotlightHideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                self.spotlightHideTask = nil
                self.fadeSpotlight(to: 0)
            }
        }
    }

    /// Ease the scrim alpha toward `target` (~0.15s exponential chase at
    /// ~60fps). One loop chases whatever the current target is, so a
    /// retarget mid-fade just bends the curve instead of restarting it.
    private func fadeSpotlight(to target: CGFloat) {
        spotlightTargetAlpha = target
        guard spotlightFadeTask == nil else { return }
        spotlightFadeTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                let t = self.spotlightTargetAlpha
                let d = t - self.spotlightAlpha
                if abs(d) < 0.012 {
                    self.spotlightAlpha = t
                    if t <= 0 { self.spotlightProposalID = nil }
                    self.spotlightFadeTask = nil
                    self.needsDisplay = true
                    return
                }
                self.spotlightAlpha += d * 0.35
                self.needsDisplay = true
            }
        }
    }

    /// In-flight manual glide (see `glideScroll`).
    private var spotlightGlideTask: Task<Void, Never>?

    /// Manually animated scroll: per-frame MODEL bounds updates. A CA
    /// implicit bounds animation (`allowsImplicitAnimation` +
    /// `scrollToVisible`) discards the trailing band's backing before the
    /// glide starts — a visible "torn strip" at the viewport edge — and its
    /// presentation-only motion never triggers draw, so the scrim can't
    /// repaint mid-glide either. Stepping the real bounds each frame renders
    /// through the normal synchronous scroll path, exactly like user
    /// scrolling, which never tears.
    private func glideScroll(toReveal r: CGRect) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let vis = visibleRect
        var dx: CGFloat = 0, dy: CGFloat = 0
        if r.maxX > vis.maxX { dx = r.maxX - vis.maxX }
        if r.minX < vis.minX { dx = r.minX - vis.minX }
        if r.maxY > vis.maxY { dy = r.maxY - vis.maxY }
        if r.minY < vis.minY { dy = r.minY - vis.minY }
        guard dx != 0 || dy != 0 else { return }
        let start = clip.bounds.origin
        let target = clip.constrainBoundsRect(
            CGRect(origin: CGPoint(x: start.x + dx, y: start.y + dy),
                   size: clip.bounds.size)).origin
        spotlightGlideTask?.cancel()
        spotlightGlideTask = Task { [weak self, weak clip, weak scrollView] in
            let duration = 0.28
            let t0 = CACurrentMediaTime()
            while !Task.isCancelled {
                let p = min(1, (CACurrentMediaTime() - t0) / duration)
                let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2   // ease in-out
                guard let clip, let scrollView else { return }
                clip.scroll(to: CGPoint(x: start.x + (target.x - start.x) * e,
                                        y: start.y + (target.y - start.y) * e))
                scrollView.reflectScrolledClipView(clip)
                if p >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self?.spotlightGlideTask = nil
        }
    }

    /// Last focused proposal we scrolled to, so a hover only scrolls once.
    private var lastScrolledRedactionFocusID: UUID?
    /// Hover-intent: the scheduled scroll for the currently hovered row.
    /// Retargeting the hover (or leaving the list) cancels it, so sweeping
    /// the cursor down the list never scrolls — only resting on a row does.
    private var pendingRedactionScroll: Task<Void, Never>?

    /// When the review-panel hover changes the focused proposal, bring its
    /// region into view so the highlight is visible even if off-screen.
    /// The highlight retargets instantly, but the scroll waits for hover
    /// intent (a short rest on the row) and then glides rather than jumps —
    /// a hover can target a region far outside the viewport, and scrolling
    /// once per swept row is disorienting.
    private func scrollFocusedRedactionIntoViewIfChanged() {
        let id = state.redactionFocusID
        guard id != lastScrolledRedactionFocusID else { return }
        lastScrolledRedactionFocusID = id
        pendingRedactionScroll?.cancel()
        pendingRedactionScroll = nil
        spotlightGlideTask?.cancel()
        spotlightGlideTask = nil
        guard let id, case .found(let proposals) = state.redactionScan,
              let proposal = proposals.first(where: { $0.id == id }),
              let first = proposal.detection.rects.first else { return }
        let union = proposal.detection.rects.dropFirst().reduce(first) { $0.union($1) }
        pendingRedactionScroll = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // Resolve the view rect at fire time — zoom may have changed
            // during the rest delay.
            let v = self.viewRect(forImageRect: union, scale: self.currentScale(),
                                  origin: self.imageDrawRect().origin)
            // Any part already in the viewport (even a sliver at the edge) →
            // the spotlight is visible where it is; don't move the canvas.
            // Scroll only when the region is entirely off-screen.
            guard !self.visibleRect.intersects(v) else { return }
            self.glideScroll(toReveal: v.insetBy(dx: -48, dy: -48))
        }
    }

    private func startObservingState() {
        withObservationTracking {
            // Touch all observable properties so changes invalidate.
            _ = state.annotations
            _ = state.croppedRect
            _ = state.focusRect
            _ = state.focusWorkingRect
            _ = state.pendingCrop
            _ = state.selectedTool
            _ = state.sidebarPanelMode
            _ = state.imageTextSearchQuery
            _ = state.imageTextSearchScope
            _ = state.imageTextSearchScanStage
            _ = state.selectedColor
            _ = state.selectedAnnotationIDs
            _ = state.primarySelectionID
            _ = state.showingEnhanced
            _ = state.enhancedImage
            _ = state.enhanceRunning
            // Gates `ensureRecognition` while a Live Text read waits for its
            // enhanced base. Tracking it here is what restarts recognition the
            // moment the wait ends — including the no-text case, where no base
            // changes and nothing else would invalidate.
            _ = state.liveTextAwaitingEnhancement
            // The cutout is an alternate base exactly like the enhanced one
            // (`displayBase` returns it first), so the canvas must repaint when
            // it arrives or is toggled. Without these, Remove Background left
            // the canvas showing the old image: nothing it writes is observed
            // here — `setShowingCutout` only touches `showingEnhanced` when it
            // was already true, and `markDirty` sets `isDirty`, which the canvas
            // does not track. The repaint then depended on some unrelated
            // observed property happening to change afterwards, which is why it
            // looked correct on some machines and not others, and why switching
            // captures and back "fixed" it.
            _ = state.showingCutout
            _ = state.cutoutImage
            _ = state.redactionScan
            _ = state.redactionFocusID
            // Drive the freehand-blur brush ring: changing either of these
            // resizes/reshapes the hover cursor, so they must invalidate too.
            _ = state.blurRegionShape
            _ = state.blurBrushWidth
        } onChange: { [weak self] in
            Task { @MainActor in
                if self?.isEditingText == true, self?.state.selectedTool != .text {
                    self?.commitTextEditing(reselect: false)
                }
                self?.handleOCRModeState()
                self?.debugStateInvalidationCount += 1
                self?.needsDisplay = true
                self?.scrollFocusedRedactionIntoViewIfChanged()
                self?.updateRedactionSpotlight()
                self?.refreshHoverCursor()     // e.g. brush-width slider moved
                self?.startObservingState()    // re-subscribe (observation is one-shot)
            }
        }
    }

    // MARK: - Drawing

    /// Pre-scaled base-image blit, keyed by everything that changes its
    /// pixels. The cached image is rendered once at the draw size (in device
    /// pixels) so per-frame drawing is a 1:1 copy instead of a full-resolution
    /// interpolation.
    private var baseBlitCache: (image: NSImage, base: ObjectIdentifier,
                                crop: CGRect?, contentClip: CGRect?, size: CGSize,
                                backing: CGFloat, baseScale: CGFloat)?

    /// Stand-in shown while a large base renders in the background, keyed the
    /// same way as `baseBlitCache` so it is discarded on any base change.
    private var previewBlitCache: (image: NSImage, base: ObjectIdentifier,
                                   crop: CGRect?, contentClip: CGRect?, size: CGSize,
                                   backing: CGFloat, baseScale: CGFloat)?
    /// The base a background blit is currently rendering, so a redraw during
    /// the render does not start a second one.
    private var pendingBlitBase: ObjectIdentifier?
    private var fullBlitTask: Task<Void, Never>?
    /// Above this, the blit moves off the main thread behind a preview.
    /// Measured on an Intel Mac: a 2.6MP base blits in 5ms and a 5.7MP in
    /// 14ms — fine synchronously — but an Enhance-upscaled 112.9MP base took
    /// **1480ms**, freezing the app on every switch to that capture. The
    /// package read is only 3-6ms because `decodeCGImageFromPNG` is lazy; this
    /// blit is where those pixels are finally decoded and scaled.
    /// Above this many OUTPUT pixels the base renders off the main thread
    /// behind `state.placeholderImage`.
    ///
    /// MEASURED, and the reasoning is not what it looks like: the first blit of
    /// a freshly-opened capture is dominated by the PNG DECODE, not by pixels
    /// drawn. On an i9-9880H it cost 52-64ms at 3360x1698 and an unchanged
    /// 46-64ms at 2048 — 39% fewer pixels, same time — while a second blit of
    /// the same, now-decoded image costs ~15ms. So rendering less cannot help;
    /// only getting the decode off the main thread does. The threshold sits
    /// below the 5.7-7.1MP captures that were stalling the strip, and above
    /// small captures whose sync blit is a few ms and needs no stand-in.
    private static let asyncBlitPixelThreshold = 5_000_000


    /// Render the scaled base. `nonisolated` so the expensive case can run off
    /// the main thread — everything it touches is a value or a `CGImage`, and
    /// the window's colour space is read on the main actor and passed in.
    nonisolated static func renderBlit(
        base: CGImage, crop: CGRect?, contentClip: CGRect?, baseScale: CGFloat,
        drawRect: CGRect, target: (w: Int, h: Int), windowColorSpace: CGColorSpace?
    ) -> NSImage {
        let displayed: CGImage
        if let crop {
            displayed = CanvasExpander.viewportBase(
                from: base, crop: crop, contentClip: contentClip, baseScale: baseScale)
        } else {
            displayed = base
        }
        // Blit in the SOURCE's colorspace: the capture is raw framebuffer bytes
        // tagged with the display profile, and the window composites in that
        // same space — a DeviceRGB intermediate forces a one-way conversion
        // that visibly lightens dark text.
        let blitSpace = (displayed.colorSpace?.model == .rgb ? displayed.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: target.w, height: target.h,
            bitsPerComponent: 8, bytesPerRow: 0, space: blitSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(cgImage: displayed, size: drawRect.size)
        }
        ctx.interpolationQuality = blitInterpolation(
            srcW: displayed.width, srcH: displayed.height, dstW: target.w, dstH: target.h)
        ctx.draw(displayed, in: CGRect(x: 0, y: 0, width: target.w, height: target.h))
        guard var scaled = ctx.makeImage() else {
            return NSImage(cgImage: displayed, size: drawRect.size)
        }
        // Screen-faithful display: ASSIGN the window's backing space (no byte
        // conversion) so the draw is an identity colour-match.
        if let ws = windowColorSpace, ws.model == .rgb,
           let assigned = scaled.copy(colorSpace: ws) {
            scaled = assigned
        }
        return NSImage(cgImage: scaled, size: drawRect.size)
    }

    /// Render the full-resolution blit in the background and swap it in.
    /// Results are discarded if the base changed while rendering — a stale
    /// blit would show the previous capture's pixels.
    private func startFullBlitIfNeeded(base: CGImage, crop: CGRect?, contentClip: CGRect?,
                                       baseScale: CGFloat, drawRect: CGRect,
                                       backing: CGFloat, target: (w: Int, h: Int)) {
        let key = ObjectIdentifier(base)
        guard pendingBlitBase != key else { return }
        // Cancel any blit for a base we have already navigated away from.
        // Without this, flicking between enhanced captures leaves multi-second
        // renders running whose results are discarded — observed burning ~2s of
        // CPU while the INCOMING capture was trying to paint.
        fullBlitTask?.cancel()
        pendingBlitBase = key
        let space = window?.colorSpace?.cgColorSpace
        fullBlitTask = Task { @MainActor [weak self] in
            // Settle first: a CoreGraphics draw cannot be interrupted once it
            // starts, so the only way not to waste it is not to begin. Flicking
            // through captures now starts no full blit at all.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.pendingBlitBase == key else { return }
            let image = await Task.detached(priority: .userInitiated) {
                Self.renderBlit(base: base, crop: crop, contentClip: contentClip,
                                baseScale: baseScale, drawRect: drawRect,
                                target: target, windowColorSpace: space)
            }.value
            guard !Task.isCancelled, self.pendingBlitBase == key else { return }
            self.pendingBlitBase = nil
            self.fullBlitTask = nil
            self.debugBaseBlitRenderCount += 1
            self.baseBlitCache = (image, key, crop, contentClip, drawRect.size,
                                  backing, baseScale)
            self.previewBlitCache = nil
            self.needsDisplay = true
        }
    }

    /// Target pixel size for the base blit. Renders at the base's native
    /// (possibly Enhance-upscaled) density — `drawRect × backing × baseScale` —
    /// so an upscaled Enhance result shows its added detail on canvas instead of
    /// being downsampled to source resolution. Capped to the base's own pixels
    /// (no point oversampling) and to `maxDimension` (bounds blit memory for big
    /// upscales). `baseScale` is `state.displayScale` (1 when not enhanced).
    nonisolated static func baseBlitPixelSize(
        drawRect: CGSize, backing: CGFloat, baseScale: CGFloat,
        nativePixels: CGSize, maxDimension: Int = 8192
    ) -> (w: Int, h: Int) {
        func dim(_ pt: CGFloat, _ native: CGFloat) -> Int {
            max(1, min(Int(native), maxDimension, Int((pt * backing * baseScale).rounded())))
        }
        return (dim(drawRect.width, nativePixels.width),
                dim(drawRect.height, nativePixels.height))
    }
    /// Test hook: how many times the scaled base was actually re-rendered.
    private(set) var debugBaseBlitRenderCount = 0

    /// Test hook: how many times observed state has invalidated the canvas.
    /// `needsDisplay` can't stand in for this — an NSView with no window never
    /// reports it — so tests that need to know "would this repaint?" read the
    /// counter instead.
    private(set) var debugStateInvalidationCount = 0

    /// Interpolation for the base blit. Integer upscales (a 1x capture on a
    /// 2x canvas at 100% zoom) use nearest-neighbor so text stays exactly as
    /// crisp as the framebuffer — every source pixel becomes an exact nxn
    /// block, the same policy pixel-focused tools use. Fractional scales and
    /// downscales keep smooth resampling (nearest would shimmer/alias there).
    nonisolated static func blitInterpolation(
        srcW: Int, srcH: Int, dstW: Int, dstH: Int
    ) -> CGInterpolationQuality {
        guard srcW > 0, srcH > 0 else { return .high }
        let sx = Double(dstW) / Double(srcW)
        let sy = Double(dstH) / Double(srcH)
        let isIntegerUpscale = sx >= 1
            && abs(sx - sx.rounded()) < 0.001
            && abs(sx - sy) < 0.001
        return isIntegerUpscale ? .none : .high
    }

    /// Layer filter for the scroll view's GPU magnification — the same rule as
    /// `blitInterpolation`, for the same reason.
    ///
    /// Zoom scales an ALREADY-rasterised layer on the GPU (the blit cache does
    /// not key on zoom, so it never re-renders), and the layer's filter decides
    /// how those pixels are sampled. Nearest pixel-doubles, which is what a
    /// screenshot tool should do at 100%/200%/300% — but only at whole
    /// multiples. `zoomStep` is 1.25 applied multiplicatively (1.25, 1.5625,
    /// 1.953…), so in practice zoom is almost never whole, and nearest then
    /// duplicates some source pixels and not others: glyph stems thicken
    /// unevenly and text looks chewed. Linear resamples smoothly there.
    ///
    /// Most visible on a 1x display, where the layer carries half the linear
    /// resolution of a Retina one, so the unevenness lands directly on glyph
    /// pixels instead of being averaged away.
    ///
    /// Below 1x the layer uses `minificationFilter` and this value is unused —
    /// it still returns `.linear` rather than leaving a stale `.nearest`
    /// behind. Pure for testing.
    nonisolated static func magnificationFilter(forZoom zoom: CGFloat) -> CALayerContentsFilter {
        guard zoom >= 1 else { return .linear }
        return abs(zoom - zoom.rounded()) < 0.001 ? .nearest : .linear
    }

    /// Density to rasterise the canvas layer at, for a given zoom.
    ///
    /// The layer used to rasterise at `backingScaleFactor` no matter the zoom,
    /// so the GPU stretched or shrank a texture holding exactly one texel per
    /// point. At any zoom but 100% every screen pixel then came out of a
    /// resample with no spare resolution to draw on — which is why 100% matches
    /// the exported PNG exactly and 94% visibly does not, and why a 2x Retina
    /// canvas hides the problem: it has four times the texels to spend.
    ///
    /// Zooming IN raises it, so the GPU is not stretching a texture that holds
    /// one texel per point.
    ///
    /// Zooming OUT does NOT lower it, and that asymmetry is the point. Dropping
    /// below native discards detail before the GPU ever sees it, and it put a
    /// cliff at exactly 100%: at 1.0 the blit is an identity copy
    /// (`blitInterpolation` gives `.none` for an integer upscale) and looks
    /// pristine; at 0.98 the target became 0.98 of native, so every pixel took
    /// a Lanczos downsample and one-pixel glyph stems softened — a 2% zoom
    /// change flipping the image from perfect to blurry. Holding full density
    /// lets the GPU reduce from ALL the source detail (supersampling, with
    /// mipmaps), and means zooming out never re-rasterises, so that direction
    /// is smooth for free.
    ///
    /// Capped because the backing store grows with the SQUARE of this — the
    /// same 8192-pixel budget `baseBlitPixelSize` already clamps to. Pure for
    /// testing.
    nonisolated static func canvasRasterScale(
        backing: CGFloat, zoom: CGFloat, drawSize: CGSize, maxDimension: CGFloat = 8192
    ) -> CGFloat {
        let ideal = max(0.01, backing * max(1, zoom))
        let longest = max(drawSize.width, drawSize.height)
        guard longest > 0 else { return ideal }
        return min(ideal, max(0.01, maxDimension / longest))
    }

    /// Re-apply the layer filter for the current zoom. Called on init, on
    /// window moves (layer backing can be re-created), and on every zoom
    /// change — the filter is a property of the zoom, not a one-time setting.
    func applyMagnificationFilter() {
        let zoom = (enclosingScrollView as? EditorCanvasScrollView)?.magnification
            ?? state.zoom
        layer?.magnificationFilter = Self.magnificationFilter(forZoom: zoom)
        // Mipmapped downscaling — see EditorCanvasScrollView.applyMagnificationFilter.
        // The layer default (.linear) undersamples at fit zoom and thins text.
        layer?.minificationFilter = .trilinear
        // Redraw at the SETTLED zoom.
        //
        // AppKit drives `contentsScale` from the animating magnification, and
        // the last frame it samples lands just short of the target: from 70% up
        // to 100% it stops around 0.99, leaving a backing store of 1767px that
        // the GPU then stretches to 1785 — an upscale, hence soft. Coming DOWN
        // to 100% it stops around 1.008, which is 1800px squeezed into 1785 —
        // supersampled, hence sharp. That asymmetry is why zooming in to 100%
        // looked worse than zooming out to it.
        //
        // Nothing marked the view dirty afterwards, so that final animation
        // frame was what stayed on screen. Redrawing here re-rasterises at the
        // settled scale. Cheap: the blit is cached, so this is a composite, not
        // a re-render — the expensive `contentsScale` invalidation that made
        // zooming clunky is gone.
        needsDisplay = true
    }

    /// Test hook: how many times the canvas actually re-rasterised at a new
    /// density. A zoom burst must move this by one, not once per step.
    private(set) var debugRasterCommitCount = 0

    /// Bounded retries for one zoom, so a scale that never converges cannot
    /// spin the run loop repainting forever.
    // `layer.contentsScale` is AppKit's to own, and it is not the place to fix a
    // soft canvas. It used to be corrected here, after traces showed paints at
    // `mag=1.0000 contextScale=0.9907`, but every write was reverted within a
    // frame — the retries only bought two extra full-canvas redraws per zoom.
    // The reason is that 0.9907 was the truth: `magnification` is the model
    // value and the animator had left the APPLIED magnification short of it, so
    // AppKit was keeping the layer honest and we were the ones lying. Settling
    // the glide onto its target fixes it at the source — see
    // `EditorCanvasScrollView.glideSettleNudge`.

    /// Density the blit should be produced at.
    ///
    /// COMPUTED, never read back from `layer.contentsScale`. AppKit owns that
    /// property for a magnified layer-backed scroll view — it keeps it at
    /// `backing x magnification` itself, and overwrites anything set here
    /// before the next draw. Reading it back meant that zooming OUT sized the
    /// blit below native (a trace showed a 1768x1090 blit of a 1785x1100 base
    /// while sitting at 100%), throwing away detail the GPU then could not
    /// recover — the missing clarity at 100%, and the cliff just below it.
    ///
    /// AppKit's own value is right for zooming IN, which is why that direction
    /// always logged CAPPED-AT-NATIVE and looked correct. All this needs to add
    /// is the floor.
    var canvasRasterScale: CGFloat {
        let zoom = (enclosingScrollView as? EditorCanvasScrollView)?.magnification
            ?? state.zoom
        return Self.canvasRasterScale(
            backing: window?.backingScaleFactor ?? 2,
            zoom: zoom,
            drawSize: imageDrawRect().size)
    }

    /// The base image (cropped if `crop` is set) scaled to `drawRect`'s size
    /// at the window's backing scale, served from `baseBlitCache` when the
    /// base, crop, target size, and backing scale all match.
    func baseBlitImage(base: CGImage, crop: CGRect?, contentClip: CGRect?,
                       baseScale: CGFloat, drawRect: CGRect,
                       previewBase: CGImage? = nil) -> NSImage {
        // The layer's density, NOT the raw backing scale: `contentsScale`
        // follows the zoom (see `canvasRasterScale`), so the blit is sized for
        // the resolution the canvas is actually rasterised at. `drawRect.size`
        // stays native — zoom enters through this scale, and the cache keys on
        // it, so a zoom change re-renders while scrolling at a fixed zoom keeps
        // hitting the cache.
        let backing = canvasRasterScale
        if let c = baseBlitCache, c.base == ObjectIdentifier(base), c.crop == crop,
           c.contentClip == contentClip, c.size == drawRect.size, c.backing == backing,
           c.baseScale == baseScale {
            return c.image
        }

        // Large bases (an Enhance-upscaled capture) render OFF the main thread
        // behind a preview, so switching to one no longer freezes the app.
        let key = ObjectIdentifier(base)
        let fullSize = Self.baseBlitPixelSize(
            drawRect: drawRect.size, backing: backing, baseScale: baseScale,
            nativePixels: CGSize(width: base.width, height: base.height))
        if fullSize.w * fullSize.h > Self.asyncBlitPixelThreshold {
            if let p = previewBlitCache, p.base == key, p.crop == crop,
               p.contentClip == contentClip, p.size == drawRect.size,
               p.backing == backing, p.baseScale == baseScale {
                startFullBlitIfNeeded(base: base, crop: crop, contentClip: contentClip,
                                      baseScale: baseScale, drawRect: drawRect,
                                      backing: backing, target: fullSize)
                return p.image
            }
            // The preview deliberately blits the UN-ENHANCED source rather than
            // a downscaled enhanced base: the enhanced CGImage is the expensive
            // thing to touch at all (its PNG is still undecoded), so sampling it
            // at any size would pay the same decode. The source is the same
            // picture, already small, and reads as "not yet sharpened" instead
            // of "broken" — which a blank canvas would not.
            let previewSource = previewBase ?? base
            let previewTarget = Self.baseBlitPixelSize(
                drawRect: drawRect.size, backing: backing, baseScale: 1,
                nativePixels: CGSize(width: previewSource.width, height: previewSource.height))
            // The crop is in SOURCE pixels and `viewportBase` scales it by
            // baseScale, so a stand-in of a different size needs its own ratio
            // or a cropped capture previews mis-framed. base.width / baseScale
            // recovers the source width. Yields exactly 1 for the un-enhanced
            // source, matching the previous hard-coded value.
            let previewScale = previewSource === base
                ? baseScale
                : CGFloat(previewSource.width) * baseScale / CGFloat(base.width)
            let previewImage = Self.renderBlit(
                base: previewSource, crop: crop, contentClip: contentClip,
                baseScale: previewScale,
                drawRect: drawRect, target: previewTarget,
                windowColorSpace: window?.colorSpace?.cgColorSpace)
            previewBlitCache = (previewImage, key, crop, contentClip, drawRect.size,
                                backing, baseScale)
            startFullBlitIfNeeded(base: base, crop: crop, contentClip: contentClip,
                                  baseScale: baseScale, drawRect: drawRect,
                                  backing: backing, target: fullSize)
            return previewImage
        }
        let image = Self.renderBlit(base: base, crop: crop, contentClip: contentClip,
                                    baseScale: baseScale, drawRect: drawRect,
                                    target: fullSize,
                                    windowColorSpace: window?.colorSpace?.cgColorSpace)
        debugBaseBlitRenderCount += 1
        baseBlitCache = (image, ObjectIdentifier(base), crop, contentClip, drawRect.size, backing, baseScale)
        previewBlitCache = nil
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let drawRect = imageDrawRect()

        // 0. Background layer, drawn behind the base so it shows through the
        // base's transparent regions (Cut holes, a blank canvas). A committed
        // fill paints that solid color; nil (transparent) paints the standard
        // checkerboard so the user can see the canvas is see-through. This is an
        // editor-only cue — the checkerboard is never baked into an export
        // (the compositor fills only a non-nil backgroundFill).
        if let fill = state.backgroundFill {
            fill.nsColor.setFill()
            drawRect.fill()
        } else {
            // The standard transparency grid — same look as `.cut` holes, so
            // every see-through surface in the editor is consistent.
            drawCheckerboard(in: drawRect, visible: dirtyRect)
        }

        // 1. Active base image (original or enhanced), cropped if a crop is
        // committed. Blitted via a cache pre-scaled to the draw size: the
        // canvas redraws fully on every mouse event of a drag, and re-
        // interpolating a full-resolution capture each tick is the dominant
        // draw cost — the base pixels don't change between ticks.
        let blit = baseBlitImage(base: state.displayBase, crop: state.croppedRect,
                                 contentClip: state.contentClip,
                                 baseScale: state.displayScale, drawRect: drawRect,
                                 // Stand-in drawn while the real base renders.
                                 // Prefer the package's already-decoded 720px
                                 // thumbnail: the un-enhanced source is itself
                                 // an undecoded PNG, so using it paid the same
                                 // ~45ms decode the preview exists to avoid.
                                 previewBase: state.placeholderImage
                                     ?? (state.displayBase === state.sourceImage
                                         ? nil : state.sourceImage))
        // Interpolation must be judged against the CONTEXT this draw lands in,
        // which is `layer.contentsScale` — AppKit's value, tracking magnification
        // — NOT the density the blit was sized at. Those differ whenever the
        // zoom is below 100%: the blit is held at native (all detail kept) while
        // the context is smaller, so Core Graphics has to reduce. Judging by the
        // blit's own density made src == dst, which picked `.none` — and NEAREST
        // downsampling DROPS rows instead of blending them, shearing thin slices
        // out of glyphs. That is the "text looks truncated" at 95%, and it is a
        // different failure from blur: dropped detail, not softened detail.
        let contextScale = layer?.contentsScale ?? window?.backingScaleFactor ?? 2
        let interp: NSImageInterpolation = {
            guard let rep = blit.representations.first else { return .high }
            let q = Self.blitInterpolation(
                srcW: rep.pixelsWide, srcH: rep.pixelsHigh,
                dstW: Int((drawRect.width * contextScale).rounded()),
                dstH: Int((drawRect.height * contextScale).rounded()))
            return q == .none ? .none : .high
        }()
        blit.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: [.interpolation: interp])

        // 2. Annotations (image-space → view-space)
        let scale = currentScale()
        for annotation in state.annotations where annotation.id != state.editingAnnotationID {
            drawTransformed(annotation, scale: scale, origin: drawRect.origin)
        }

        // 2.5 Selection overlay — moved to SelectionChromeOverlay (non-magnified
        // overlay that keeps handles at a constant on-screen size regardless of zoom).

        // 2.7 Smart-redaction proposals — dashed, tinted overlays deliberately
        // distinct from committed annotations. Kept proposals draw solid amber;
        // skipped ones dim. The row hovered in the review panel gets a
        // spotlight: everything else sinks under a light scrim (same idiom as
        // the focus-crop exterior dim) and its highlight draws bright on top.
        // The scrim is sticky + faded (see `updateRedactionSpotlight`), so it
        // tracks `spotlightProposalID`/`spotlightAlpha`, not the instant
        // `redactionFocusID` the yellow highlight uses.
        if case .found(let proposals) = state.redactionScan {
            let focused = proposals.first { $0.id == state.redactionFocusID }
            let spotlight = proposals.first { $0.id == spotlightProposalID }
            for proposal in proposals where proposal.id != focused?.id {
                for rect in proposal.detection.rects {
                    drawRedactionProposal(rect, kept: proposal.isKept, focused: false,
                                          scale: scale, origin: drawRect.origin)
                }
            }
            if let spotlight, spotlightAlpha > 0.005 {
                let dim = NSBezierPath(rect: imageDrawRect())
                for rect in spotlight.detection.rects {
                    let v = viewRect(forImageRect: rect, scale: scale, origin: drawRect.origin)
                    dim.append(NSBezierPath(rect: v.insetBy(dx: -3, dy: -3)).reversed)
                }
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(spotlightAlpha).setFill()
                dim.fill()
            }
            if let focused {
                for rect in focused.detection.rects {
                    drawRedactionProposal(rect, kept: focused.isKept, focused: true,
                                          scale: scale, origin: drawRect.origin)
                }
            }
        }

        // 3. In-progress preview (live drag)
        if let start = dragStart, let current = dragCurrent {
            let previewColor = state.selectedColor
            // Live outline (casing) so what you drag matches what commits.
            let previewOutline: NSColor? = state.selectedOutlineColor.map { applyOpacity($0, opacity: state.creationOpacity) }
            let previewCasingW = (state.strokeWidth + 2 * state.outlineWidth) * scale
            // Preview under the SAME drop shadow the committed annotation gets, so
            // what you drag matches what settles — and a light/white outline stays
            // visible during the drag (the shadow delineates it) instead of only
            // appearing on commit.
            let previewCG = NSGraphicsContext.current?.cgContext
            let previewCastsShadow: Bool = {
                switch state.selectedTool {
                case .arrow, .rectangle, .ellipse, .line, .badge, .pen, .penArrow: return true
                default: return false
                }
            }()
            if previewCastsShadow {
                previewCG?.saveGState()
                applyShadow(state.shadowDefault(for: state.selectedTool), to: previewCG, yDown: false, scale: scale)
            }
            switch state.selectedTool {
            case .arrow:
                let s = viewPoint(forImagePoint: start, scale: scale, origin: drawRect.origin)
                let e = viewPoint(forImagePoint: current, scale: scale, origin: drawRect.origin)
                drawArrowPreview(from: s, to: e, color: previewColor, strokeWidth: state.strokeWidth * scale,
                                 outlineColor: previewOutline, outlineWidth: state.outlineWidth * scale)
            case .rectangle:
                let r = viewRect(forImageRect: rectFromPoints(start, current),
                                 scale: scale, origin: drawRect.origin)
                // Round the live preview with the same radius the committed
                // rectangle will use (shapeCreationStyle → shapeCornerRadius), so
                // the corners read as round throughout the drag rather than
                // snapping round only on release.
                let radius = clampedCornerRadius(state.shapeCornerRadius * scale, for: r)
                let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
                // Fill previews live too (same fill + opacity the committed
                // shape will get), so a filled rectangle doesn't pop in only
                // on release.
                if let oc = previewOutline {
                    oc.setStroke()
                    let cp = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
                    cp.lineWidth = previewCasingW
                    cp.stroke()
                }
                if let fill = state.shapeFillColor {
                    applyOpacity(fill, opacity: state.creationOpacity).setFill()
                    p.fill()
                }
                previewColor.setStroke()
                p.lineWidth = state.strokeWidth * scale
                p.stroke()
            case .crop:
                let imgBounds = CGRect(origin: .zero, size: currentImageSize())
                let imgRect = cropDragRect(from: start, to: current, bounds: imgBounds)
                let r = viewRect(forImageRect: imgRect, scale: scale, origin: drawRect.origin)
                drawCropMarquee(in: r, viewBounds: bounds)
            case .select, .textSelect, .hand:
                break   // neutral / live-text / pan tools draw no drag preview
            case .text:
                // Solid accent frame + resize dots while dragging out the box,
                // matching the chrome it keeps through editing and selection.
                let r = viewRect(forImageRect: rectFromPoints(start, current),
                                 scale: scale, origin: drawRect.origin)
                drawTextBoxChrome(r)
            case .ellipse:
                let r = viewRect(forImageRect: rectFromPoints(start, current),
                                 scale: scale, origin: drawRect.origin)
                let p = NSBezierPath(ovalIn: r)
                if let oc = previewOutline {
                    oc.setStroke()
                    let cp = NSBezierPath(ovalIn: r)
                    cp.lineWidth = previewCasingW
                    cp.stroke()
                }
                if let fill = state.shapeFillColor {
                    applyOpacity(fill, opacity: state.creationOpacity).setFill()
                    p.fill()
                }
                previewColor.setStroke()
                p.lineWidth = state.strokeWidth * scale
                p.stroke()
            case .line:
                let s = viewPoint(forImagePoint: start, scale: scale, origin: drawRect.origin)
                let e = viewPoint(forImagePoint: current, scale: scale, origin: drawRect.origin)
                drawConnector(from: s, to: e, width: state.strokeWidth * scale, color: previewColor,
                              dash: state.dashStyle, startCap: .none, endCap: .none,
                              outlineColor: previewOutline, outlineWidth: state.outlineWidth * scale)
            case .badge:
                let dist = hypot(current.x - start.x, current.y - start.y)
                let radius = (dist < 8 ? state.badgeRadius : max(8, dist)) * scale
                let c = viewPoint(forImagePoint: start, scale: scale, origin: drawRect.origin)
                if let oc = previewOutline {
                    let rr = radius + state.outlineWidth * scale
                    oc.setFill()
                    NSBezierPath(ovalIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)).fill()
                }
                NSColor.systemRed.withAlphaComponent(0.6).setFill()
                NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
            case .pen:
                if !penPoints.isEmpty {
                    let viewPts = penPoints.map { viewPoint(forImagePoint: $0, scale: scale, origin: drawRect.origin) }
                    let p = PenPath.smoothedPath(viewPts, finished: false)
                    PenDiag.frame(rawViewPoints: viewPts, path: p,
                                  scale: scale, origin: drawRect.origin)
                    p.lineCapStyle = .round
                    p.lineJoinStyle = .round
                    if let oc = previewOutline { oc.setStroke(); p.lineWidth = previewCasingW; p.stroke() }
                    previewColor.setStroke()
                    p.lineWidth = state.strokeWidth * scale   // live stroke width
                    p.stroke()
                }
            case .penArrow:
                if !penPoints.isEmpty {
                    let viewPts = penPoints.map { viewPoint(forImagePoint: $0, scale: scale, origin: drawRect.origin) }
                    PenDiag.frame(rawViewPoints: viewPts,
                                  path: PenPath.smoothedPath(viewPts, finished: false),
                                  scale: scale, origin: drawRect.origin)
                    // Same helper as the committed render, so what you drag is
                    // exactly what commits (stroke + tangent-oriented heads).
                    drawPenArrow(points: viewPts, color: previewColor, strokeWidth: state.strokeWidth * scale,
                                 startCap: state.arrowStartCap, endCap: state.arrowEndCap,
                                 outlineColor: previewOutline, outlineWidth: state.outlineWidth * scale,
                                 finished: false)   // live profile while dragging
                }
            case .blur:
                drawBlurPreview(start: start, current: current, scale: scale, origin: drawRect.origin)
            }
            if previewCastsShadow { previewCG?.restoreGState() }
        }

        // Text box being inline-edited: draw the same frame + resize dots as the
        // drag/selected states so the box stays visible while typing (the editor
        // view itself is transparent). Follows the box as it grows.
        if inlineEditor != nil, let rect = editingBoxRect {
            drawTextBoxChrome(viewRect(forImageRect: rect, scale: scale, origin: drawRect.origin))
        }

        // 4. Pending crop preview (dashed marquee + brackets + hint) is drawn by
        //    SelectionChromeOverlay now (constant on-screen size).

        // 5. Focus-crop overlay (exterior dim only; outline + brackets in overlay)
        drawFocusOverlay(scale: scale, origin: drawRect.origin)

        // OCR overlays are transient editor chrome and are never exported.
        if state.showsImageTextSearchPanel {
            drawImageTextSearch(scale: scale, origin: drawRect.origin)
        } else if state.selectedTool == .textSelect {
            drawLiveText(scale: scale, origin: drawRect.origin)
        }

        // The live rotation readout is drawn by SelectionChromeOverlay now.
    }

    // MARK: - Coordinate conversion

    private func currentImageSize() -> CGSize {
        if let crop = state.croppedRect { return crop.size }
        return CGSize(width: state.sourceImage.width, height: state.sourceImage.height)
    }

    private func currentScale() -> CGFloat {
        let imgSize = currentImageSize()
        // The canvas frame is NATIVE image size + 2*imagePadding (zoom is applied as
        // scroll-view magnification, not a frame resize); back the padding out so this
        // returns the base fit scale. Zoom enters chrome math only via ChromeProjection.
        let inner = Self.imagePadding * 2
        let sx = max(1, bounds.width - inner) / imgSize.width
        let sy = max(1, bounds.height - inner) / imgSize.height
        return min(sx, sy)
    }

    /// Inputs the SelectionChromeOverlay needs to build a ChromeProjection: the
    /// base fit scale and the image's canvas-space draw origin. (Magnification +
    /// scroll origin come from the enclosing scroll view.)
    func chromeProjectionInputs() -> (scale: CGFloat, drawOrigin: CGPoint) {
        (currentScale(), imageDrawRect().origin)
    }

    private func imageDrawRect() -> CGRect {
        let imgSize = currentImageSize()
        let scale = currentScale()
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        let x = (bounds.width - drawW) / 2
        let y = (bounds.height - drawH) / 2
        return CGRect(x: x, y: y, width: drawW, height: drawH)
    }

    private func imagePoint(forViewPoint p: CGPoint) -> CGPoint {
        let scale = currentScale()
        let origin = imageDrawRect().origin
        return CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
    }

    private func viewPoint(forImagePoint p: CGPoint, scale: CGFloat, origin: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + origin.x, y: p.y * scale + origin.y)
    }

    private func viewRect(forImageRect r: CGRect, scale: CGFloat, origin: CGPoint) -> CGRect {
        CGRect(
            x: r.origin.x * scale + origin.x,
            y: r.origin.y * scale + origin.y,
            width: r.size.width * scale,
            height: r.size.height * scale
        )
    }

    private func rectFromPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    // MARK: - Annotation rendering

    /// Wrap `drawAnnotation` in the annotation's VIEW-space transform. The
    /// per-case code converts image→view internally, so the matrix is built
    /// about the view-space center (y-down ⇒ positive angle = clockwise).
    /// Blur is EXCLUDED: live blur samples the already-drawn base in view
    /// space, so wrapping would rotate the sampled pixels — its mask is
    /// transformed inside `drawLiveBlur` instead.
    private func drawTransformed(_ annotation: Annotation, scale: CGFloat, origin: CGPoint) {
        let t = annotation.transform
        let shadowCtx = NSGraphicsContext.current?.cgContext
        shadowCtx?.saveGState()
        defer { shadowCtx?.restoreGState() }
        if geometryCastsShadow(annotation.geometry) {
            // CGContext.setShadow offset is applied in the context's BASE (un-flipped)
            // coordinate space, independent of the view's isFlipped state. The export
            // path (y-up NSBitmapImageRep context, yDown:false) already negates the
            // height to put a positive offset.height below the shape. The canvas uses
            // the same negation — a flipped NSView doesn't flip the CGContext base
            // space, so the shadow direction must be corrected identically to y-up.
            applyShadow(annotation.style.shadow, to: shadowCtx, yDown: false, scale: scale)
        }
        guard !t.isIdentity, !annotation.geometry.isBlur,
              let ctx = NSGraphicsContext.current?.cgContext else {
            drawAnnotation(annotation, scale: scale, origin: origin)
            return
        }
        let b = geometryBounds(annotation.geometry)
        let c = viewPoint(forImagePoint: CGPoint(x: b.midX, y: b.midY),
                          scale: scale, origin: origin)
        ctx.saveGState()
        ctx.concatenate(transformMatrix(for: t, center: c))
        drawAnnotation(annotation, scale: scale, origin: origin)
        ctx.restoreGState()
    }

    private func drawAnnotation(_ annotation: Annotation, scale: CGFloat, origin: CGPoint) {
        let style = annotation.style
        let stroke = applyOpacity(style.strokeColor.nsColor, opacity: style.opacity)
        // Outline (casing): a wider stroke in `outlineColor` drawn BENEATH the
        // normal stroke — parity with AnnotationRenderer's committed/export path.
        let outlineNS = style.outlineColor.map { applyOpacity($0.nsColor, opacity: style.opacity) }
        let casingW = (style.strokeWidth + 2 * style.outlineWidth) * scale
        switch annotation.geometry {
        case let .arrow(start, end):
            let s = viewPoint(forImagePoint: start, scale: scale, origin: origin)
            let e = viewPoint(forImagePoint: end, scale: scale, origin: origin)
            drawConnector(from: s, to: e, width: style.strokeWidth * scale, color: stroke,
                          dash: style.dashStyle, startCap: style.startCap, endCap: style.endCap,
                          shaft: style.shaftStyle,
                          outlineColor: outlineNS, outlineWidth: style.outlineWidth * scale)
        case let .rectangle(rect):
            let r = viewRect(forImageRect: rect, scale: scale, origin: origin)
            let radius = clampedCornerRadius(style.cornerRadius * scale, for: r)
            let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            if let oc = outlineNS {
                drawShapeAsOneObject(NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius),
                                     fill: nil, stroke: oc, strokeWidth: casingW)
            }
            drawShapeAsOneObject(p,
                                 fill: style.fillColor.map { applyOpacity($0.nsColor, opacity: style.opacity) },
                                 stroke: stroke, strokeWidth: style.strokeWidth * scale)
        case let .text(rect, runs):
            // Text mask model: layout at `layoutW` (image space; the stored
            // `textLayoutWidth` when the box was manually shrunk narrower than
            // its text, else `rect.width`), clipped to the box `rect` itself —
            // mirrors AnnotationRenderer's `.text` case so live canvas and
            // exported/committed renders stay in parity. nil `textLayoutWidth`
            // (legacy files) makes `layoutW == rect.width`: a no-op clip,
            // identical to prior behavior.
            let vr = viewRect(forImageRect: rect, scale: scale, origin: origin)
            let layoutW = style.effectiveTextLayoutWidth(rect: rect)
            let textW = max(1, layoutW - 2 * textBoxHPadding)   // box inset by H padding
            let content = textBoxHeight(runs: runs, width: textW, lineSpacing: style.lineSpacing) * scale
            let dr = verticalAlignedRect(vr, contentHeight: content,
                                         vAlign: style.textVerticalAlignment, flipped: true)
            let padScaled = textBoxHPadding * scale
            let textWScaled = textW * scale
            let layoutX = textLayoutOriginX(alignment: style.textAlignment,
                                            boxMinX: dr.minX + padScaled,
                                            boxMaxX: dr.maxX - padScaled, layoutWidth: textWScaled)
            let layoutRect = CGRect(x: layoutX, y: dr.minY, width: textWScaled, height: dr.height)
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: vr).addClip()
            if textRunsHaveOutline(runs) {
                // Paint order: strokes first (expanding outward, round joins
                // so fat outlines don't spike), fills on top — parity with
                // AnnotationRenderer's .text case.
                let cg = NSGraphicsContext.current?.cgContext
                cg?.setLineJoin(.round)
                cg?.setLineCap(.round)
                attributedString(for: runs, opacity: style.opacity, scale: scale,
                                 alignment: style.textAlignment, lineSpacing: style.lineSpacing,
                                 pass: .stroke)
                    .draw(in: layoutRect)
                attributedString(for: runs, opacity: style.opacity, scale: scale,
                                 alignment: style.textAlignment, lineSpacing: style.lineSpacing,
                                 pass: .fill)
                    .draw(in: layoutRect)
            } else {
                attributedString(for: runs, opacity: style.opacity, scale: scale,
                                 alignment: style.textAlignment, lineSpacing: style.lineSpacing)
                    .draw(in: layoutRect)
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        case let .ellipse(rect):
            let r = viewRect(forImageRect: rect, scale: scale, origin: origin)
            let p = NSBezierPath(ovalIn: r)
            if let oc = outlineNS {
                drawShapeAsOneObject(NSBezierPath(ovalIn: r), fill: nil, stroke: oc, strokeWidth: casingW)
            }
            drawShapeAsOneObject(p,
                                 fill: style.fillColor.map { applyOpacity($0.nsColor, opacity: style.opacity) },
                                 stroke: stroke, strokeWidth: style.strokeWidth * scale)
        case let .line(start, end):
            if style.strokeWidth > 0 {
                let s = viewPoint(forImagePoint: start, scale: scale, origin: origin)
                let e = viewPoint(forImagePoint: end, scale: scale, origin: origin)
                drawConnector(from: s, to: e, width: style.strokeWidth * scale, color: stroke,
                              dash: style.dashStyle, startCap: .none, endCap: .none,
                              outlineColor: outlineNS, outlineWidth: style.outlineWidth * scale)
            }
        case let .badge(center, radius):
            let c = viewPoint(forImagePoint: center, scale: scale, origin: origin)
            let r = radius * scale
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            if let oc = outlineNS {
                let rr = r + style.outlineWidth * scale
                oc.setFill()
                NSBezierPath(ovalIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)).fill()
            }
            applyOpacity((style.fillColor ?? SerializableColor(.systemRed)).nsColor, opacity: style.opacity).setFill()
            NSBezierPath(ovalIn: rect).fill()
            drawCenteredBadgeNumber(badgeNumber(for: annotation.id, in: state.annotations) ?? 0,
                                    in: rect, fontSize: r, color: stroke)
        case let .pen(points):
            if style.strokeWidth > 0, !points.isEmpty {
                let viewPts = points.map { viewPoint(forImagePoint: $0, scale: scale, origin: origin) }
                let p = PenPath.smoothedPath(viewPts)
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                if let oc = outlineNS {
                    oc.setStroke(); p.lineWidth = casingW; p.stroke()
                }
                stroke.setStroke()
                p.lineWidth = style.strokeWidth * scale
                p.stroke()
            }
        case let .penArrow(points):
            if style.strokeWidth > 0, !points.isEmpty {
                let viewPts = points.map { viewPoint(forImagePoint: $0, scale: scale, origin: origin) }
                drawPenArrow(points: viewPts, color: stroke, strokeWidth: style.strokeWidth * scale,
                             startCap: style.startCap, endCap: style.endCap,
                             outlineColor: outlineNS, outlineWidth: style.outlineWidth * scale)
            }
        case let .blur(region):
            drawLiveBlur(region, style: style, scale: scale, origin: origin,
                         transform: annotation.transform)
        case let .image(rect, assetID):
            let r = viewRect(forImageRect: rect, scale: scale, origin: origin)
            if let overlay = state.assetImage(assetID) {
                NSImage(cgImage: overlay,
                        size: NSSize(width: overlay.width, height: overlay.height))
                    .draw(in: r, from: .zero, operation: .sourceOver,
                          fraction: style.opacity, respectFlipped: true, hints: nil)
            } else {
                // Missing asset: dashed placeholder so the object stays manipulable.
                let p = NSBezierPath(rect: r)
                p.setLineDash([4, 4], count: 2, phase: 0)
                NSColor.secondaryLabelColor.setStroke()
                p.stroke()
            }
        case let .cut(rect):
            let vr = viewRect(forImageRect: rect, scale: scale, origin: origin)
            // A cut reveals the backmost background layer: when a fill is set the
            // hole shows that color (matching the export, where the fill lands in
            // the cleared hole); with a transparent background it shows the
            // standard checkerboard cue.
            if let fill = state.backgroundFill {
                fill.nsColor.setFill()
                vr.fill()
            } else {
                drawCheckerboard(in: vr)
            }
            NSColor(white: 0, alpha: 0.35).setStroke()
            let border = NSBezierPath(rect: vr); border.lineWidth = 1; border.stroke()
        }
    }

    /// Draw a committed blur region live on the canvas. Filters the source
    /// pixels via `BlurRenderer` and clips to the region shape, using the same
    /// shared code path as the save renderer so the preview matches the export.
    private func drawLiveBlur(_ region: BlurRegion, style: Style, scale: CGFloat, origin: CGPoint,
                              transform: AnnotationTransform = AnnotationTransform()) {
        let cropOrigin = state.croppedRect?.origin ?? .zero
        guard let (cg, bbox) = BlurRenderer.filteredRegionImage(
            region: region, mode: style.blurMode, strength: style.blurStrength,
            solidColor: BlurRenderer.solidColor(for: style),
            source: state.displayBase, cropOrigin: cropOrigin, scale: state.displayScale
        ) else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        let clip = BlurRenderer.clipPath(
            for: region,
            mapRect: { self.viewRect(forImageRect: $0, scale: scale, origin: origin) },
            mapPoint: { self.viewPoint(forImagePoint: $0, scale: scale, origin: origin) },
            mapLength: { $0 * scale }
        )
        // Transform only the mask, about the region's VIEW-space center (y-down).
        let rb = region.boundingRect
        let center = viewPoint(forImagePoint: CGPoint(x: rb.midX, y: rb.midY),
                               scale: scale, origin: origin)
        BlurRenderer.transformedClipPath(clip, transform: transform, center: center, yDown: true)
            .addClip()
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            .draw(in: viewRect(forImageRect: bbox, scale: scale, origin: origin))
    }

    /// In-progress blur preview during a create drag: a dashed outline for
    /// rect/ellipse, or the live brush path for freehand. The filtered pixels
    /// appear on mouse-up — far cheaper than filtering every drag frame.
    /// Draw a text box's chrome — a solid accent frame plus the 8 resize dots at
    /// its corners/mid-edges — in view space. Shared by the drag-out preview and
    /// the inline-editing overlay so both match the committed-selection chrome
    /// (`SelectionChromeOverlay.drawObjectChrome`).
    private func drawTextBoxChrome(_ r: CGRect) {
        NSColor.controlAccentColor.setStroke()
        let frame = NSBezierPath(rect: r); frame.lineWidth = 1.5; frame.stroke()
        let dots = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.midY),                                CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
        ]
        let d: CGFloat = 8
        for c in dots {
            let dot = NSBezierPath(ovalIn: CGRect(x: c.x - d/2, y: c.y - d/2, width: d, height: d))
            NSColor.white.setFill(); dot.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke(); dot.lineWidth = 1; dot.stroke()
        }
    }

    private func drawBlurPreview(start: CGPoint, current: CGPoint, scale: CGFloat, origin: CGPoint) {
        let accent = NSColor(red: 0x4A/255.0, green: 0x9E/255.0, blue: 0xFF/255.0, alpha: 1.0)
        switch state.blurRegionShape {
        case .freehand:
            guard let first = penPoints.first else { return }
            let p = NSBezierPath()
            p.lineWidth = state.blurBrushWidth * scale
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: viewPoint(forImagePoint: first, scale: scale, origin: origin))
            for pt in penPoints.dropFirst() {
                p.line(to: viewPoint(forImagePoint: pt, scale: scale, origin: origin))
            }
            accent.withAlphaComponent(0.35).setStroke()
            p.stroke()
        case .rect, .ellipse:
            let r = viewRect(forImageRect: rectFromPoints(start, current), scale: scale, origin: origin)
            let path = state.blurRegionShape == .ellipse
                ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
            accent.withAlphaComponent(0.12).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1
            let dashes: [CGFloat] = [5, 3]
            path.setLineDash(dashes, count: dashes.count, phase: 0)
            path.stroke()
        }
    }

    /// Live drag preview for the Arrow tool, reflecting the tool's current cap
    /// and dash choices so the preview matches what will be committed.
    private func drawArrowPreview(from start: CGPoint, to end: CGPoint, color: NSColor,
                                  strokeWidth: CGFloat = 3,
                                  outlineColor: NSColor? = nil, outlineWidth: CGFloat = 0) {
        drawConnector(from: start, to: end, width: strokeWidth, color: color,
                      dash: state.dashStyle, startCap: state.arrowStartCap, endCap: state.arrowEndCap,
                      shaft: state.arrowShaftStyle,
                      outlineColor: outlineColor, outlineWidth: outlineWidth)
    }

    /// Draw the standard transparency checkerboard inside `rect` so the user can
    /// see the region is see-through. Alternating light/dark squares mimic the
    /// familiar image-editor grid. The defaults ARE the standard look (a fine,
    /// subtle near-white + very-light-gray grid); every transparent surface —
    /// the empty/removed-background canvas backdrop and `.cut` holes alike —
    /// uses it unchanged so they all read identically. Constant on-screen size:
    /// `cell` is a point value, so the squares don't scale with canvas zoom.
    ///
    /// `dark = 0.95` (very light gray on white) — a subtle transparency grid.
    /// `visible` limits the cells actually emitted. Clipping alone does not
    /// help: the loop still runs for every cell in `rect` and only the OUTPUT
    /// is discarded. On a tall scroll capture (1706x5082) that is ~87,000
    /// `fill` calls per frame — measured at ~21ms while only 2% of the canvas
    /// was damaged, which capped scrolling at ~17fps.
    ///
    /// The grid phase stays anchored to `rect`, not to `visible`, or the
    /// pattern would shift as you scroll.
    private func drawCheckerboard(in rect: NSRect, visible: NSRect? = nil,
                                  cell: CGFloat = 10,
                                  light: CGFloat = 1.0, dark: CGFloat = 0.95) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let area = visible.map { rect.intersection($0) } ?? rect
        guard !area.isNull, area.width > 0, area.height > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: area)
        NSColor(white: light, alpha: 1).setFill(); ctx.fill(area)
        NSColor(white: dark, alpha: 1).setFill()
        // Start on the first grid line at or before the visible area, keeping
        // the row parity that `rect` would have produced.
        let rowOffset = Int(((area.minY - rect.minY) / cell).rounded(.down))
        var y = rect.minY + CGFloat(rowOffset) * cell
        var row = rowOffset
        while y < area.maxY {
            let phase = row.isMultiple(of: 2) ? 0 : cell
            let colOffset = max(0, Int(((area.minX - rect.minX - phase) / (cell * 2))
                                        .rounded(.down)))
            var x = rect.minX + phase + CGFloat(colOffset) * cell * 2
            while x < area.maxX {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += 2 * cell
            }
            y += cell; row += 1
        }
        ctx.restoreGState()
    }

    /// One smart-redaction proposal rect: dashed amber outline + light tint.
    /// Skipped proposals dim so the user sees what Apply will leave visible;
    /// the panel-hovered proposal gets a heavier outline.
    private func drawRedactionProposal(_ imageRect: CGRect, kept: Bool, focused: Bool,
                                       scale: CGFloat, origin: CGPoint) {
        let r = viewRect(forImageRect: imageRect, scale: scale, origin: origin)
        let tint = NSColor.systemOrange
        // Hovered row's region: bold, unmistakable — bright fill + thick solid
        // border (vs. the thin dashed outline of the other proposals).
        if focused {
            NSColor.systemYellow.withAlphaComponent(0.4).setFill()
            NSBezierPath(rect: r).fill()
            tint.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
            path.lineWidth = 3
            path.stroke()
            return
        }
        let alpha: CGFloat = kept ? 0.9 : 0.3
        tint.withAlphaComponent(kept ? 0.15 : 0.05).setFill()
        NSBezierPath(rect: r).fill()
        tint.withAlphaComponent(alpha).setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 1.5
        let dashes: [CGFloat] = [5, 3]
        path.setLineDash(dashes, count: dashes.count, phase: 0)
        path.stroke()
    }

    private func drawCropMarquee(in rect: CGRect, viewBounds: NSRect) {
        // No exterior dim — image stays fully visible. The dashed marching-
        // ants outline alone communicates what will be kept on commit.
        // Divide the line metrics by the scroll-view magnification so the drag-out
        // marquee renders at a CONSTANT on-screen size (2pt line, [6,4] dashes) —
        // matching the settled marquee drawn by the non-magnified chrome overlay.
        // (This view is GPU-magnified by `zoom`, so a raw 2pt line would scale.)
        let m = max(0.01, (enclosingScrollView as? EditorCanvasScrollView)?.chromeMagnification ?? 1)
        NSColor(red: 0x4A/255.0, green: 0x9E/255.0, blue: 0xFF/255.0, alpha: 1.0).setStroke()
        let p = NSBezierPath(rect: rect.insetBy(dx: 1 / m, dy: 1 / m))
        p.lineWidth = 2 / m
        let dashes: [CGFloat] = [6 / m, 4 / m]
        p.setLineDash(dashes, count: dashes.count, phase: 0)
        p.stroke()
    }

    /// Directional resize cursor for a focus handle (reuses the annotation
    /// resize cursors: diagonal for corners, vertical/horizontal for edges).
    /// Internal so the chrome overlay (Task 8 cursors) can reach it.
    static func focusResizeCursor(for handle: FocusHandle) -> NSCursor {
        switch handle {
        case .topLeft, .bottomRight: return diagonalNWSE
        case .topRight, .bottomLeft: return diagonalNESW
        case .top, .bottom:          return resizeVertical
        case .left, .right:          return resizeHorizontal
        }
    }

    /// Dim everything outside the focus rect. The white outline + viewfinder
    /// bracket anchors are drawn by SelectionChromeOverlay (constant on-screen
    /// size); only the exterior dim stays in the magnified canvas. The live
    /// focus rect during an overlay-driven drag is read from
    /// `state.focusWorkingRect` (the overlay sets it; nil when not dragging).
    private func drawFocusOverlay(scale: CGFloat, origin: CGPoint) {
        let rect = state.focusWorkingRect ?? state.effectiveFocusRect
        let v = viewRect(forImageRect: rect, scale: scale, origin: origin)
        // Dim the exterior only when a focus crop is active or being dragged.
        if state.focusRect != nil || state.focusWorkingRect != nil {
            let full = imageDrawRect()
            NSColor.black.withAlphaComponent(0.45).setFill()
            let path = NSBezierPath(rect: full)
            path.append(NSBezierPath(rect: v).reversed)
            path.windingRule = .evenOdd
            path.fill()
        }
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        onUserMouseDown?()
        if state.showsImageTextSearchPanel { return }
        if state.selectedTool == .textSelect {
            handleLiveTextMouseDown(event)
            return
        }
        // A click while editing commits the current text box first. If that click
        // landed on another object, commit AND fall through to select/drag it in
        // the same click (no extra click needed); an empty-canvas click just
        // commits (so the text tool doesn't start a new box on the commit click).
        if isEditingText {
            let p = imagePoint(forViewPoint: convert(event.locationInWindow, from: nil))
            if hitTestAnnotations(state.annotations, at: p, tolerance: 6 / currentScale()) != nil {
                commitTextEditing(reselect: false)
                // fall through to the normal hit-test + selection below
            } else {
                commitTextEditing()
                return
            }
        }
        // Double-click an existing text box (any tool) re-enters editing;
        // double-click an image object (any tool) zooms to fit it.
        if event.clickCount == 2, !state.isReadOnly {
            let p = imagePoint(forViewPoint: convert(event.locationInWindow, from: nil))
            if let id = hitTestAnnotations(state.annotations, at: p, tolerance: 6 / currentScale()),
               let a = state.annotations.first(where: { $0.id == id }) {
                if case .text = a.geometry {
                    beginEditingExisting(id)
                    return
                }
                if case .image(let rect, _) = a.geometry,
                   let scroll = enclosingScrollView as? EditorCanvasScrollView {
                    let docRect = viewRect(forImageRect: rect, scale: currentScale(),
                                           origin: imageDrawRect().origin)
                    scroll.zoomToFitDocumentRect(docRect)
                    return
                }
            }
        }
        // Block all interactions when viewing a file from the Deleted
        // folder. User must restore first.
        if state.isReadOnly { return }
        let viewP = convert(event.locationInWindow, from: nil)
        let imageP = imagePoint(forViewPoint: viewP)
        dragStartImagePoint = imageP
        mouseDownWindowPoint = event.locationInWindow
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)

        // 0) Focus-crop anchor hit-test + drag is owned by SelectionChromeOverlay
        //    now (screen-space, priority over object handles). The canvas only
        //    reaches here when the overlay's hitTest returned nil.

        // 0.25) Hand tool: pan. With a focus set, the drag repositions the focus
        //       over the image (an edit); with none, it scrolls the view.
        if state.selectedTool == .hand {
            beginImagePan(atWindowPoint: event.locationInWindow)
            return
        }

        // 0.5) Crop-tool pending-crop resize/move is owned by
        //      SelectionChromeOverlay now (screen-space hit-test + drag).

        // Object resize/rotate handle grabs (single selection AND any object's
        // visible anchor dot) are owned by SelectionChromeOverlay now — it
        // hit-tests in screen space and begins the drag. The canvas only sees
        // mouseDown here when the overlay's hitTest returned nil.

        // 2) Any object body. EXCEPT: with a drawing tool active, a press on an
        //    IMAGE object draws over it instead of grabbing it — image layers
        //    (e.g. Live Capture windows) otherwise cover the canvas and make the
        //    drawing tools unreachable. Non-image objects and the Select tool are
        //    unaffected: moving/selecting stays the Select tool's job.
        let toleranceInImage = 6 / currentScale()
        if let id = hitTestAnnotations(state.annotations, at: imageP, tolerance: toleranceInImage),
           !(isDrawingTool && (state.annotations.first { $0.id == id }?.geometry.isImage ?? false)) {
            if additive {
                // Shift/⌘-click toggles membership; no drag.
                state.toggleSelection(id)
                interactionMode = .idle
                needsDisplay = true
                return
            }
            // Plain click: keep the set if the object is already in it (so the
            // whole group moves), otherwise select only it.
            if !state.selectedAnnotationIDs.contains(id) {
                state.selectOnly(id)
            } else {
                state.primarySelectionID = id
            }
            // Start a group move: snapshot originals for every selected object.
            var originals: [UUID: Geometry] = [:]
            for a in state.annotations where state.selectedAnnotationIDs.contains(a.id) {
                originals[a.id] = a.geometry
            }
            state.recordUndoCheckpoint(action: "Move")
            interactionMode = .moving(originals: originals)
            needsDisplay = true
            return
        }

        // 3) Empty canvas.
        switch state.selectedTool {
        case .hand:
            break   // pan handled before this switch (see mouseDown)
        case .select:
            // Select tool: clear selection on a plain click, rubber-band
            // marquee on a drag.
            if !additive { state.clearSelection() }
            marqueeStart = imageP
            marqueeCurrent = imageP
            state.marqueeRect = rectFromPoints(imageP, imageP)
            interactionMode = .marquee
        case .arrow, .rectangle, .crop, .text, .ellipse, .line, .badge:
            state.clearSelection()
            dragStart = imageP
            dragCurrent = imageP
            interactionMode = .drawing
        case .pen, .penArrow:
            state.clearSelection()
            dragStart = imageP
            dragCurrent = imageP
            penPoints = [imageP]
            beginFinePointerSampling()
            PenDiag.began(tool: state.selectedTool == .pen ? "pen" : "penArrow",
                          scale: currentScale(), origin: imageDrawRect().origin,
                          strokeWidth: state.strokeWidth)
            interactionMode = .drawing
        case .blur:
            state.clearSelection()
            dragStart = imageP
            dragCurrent = imageP
            // Freehand blur accumulates a brush path; rect/ellipse rubber-band.
            if state.blurRegionShape == .freehand {
                penPoints = [imageP]
                beginFinePointerSampling()
            }
            interactionMode = .drawing
        case .textSelect:
            break   // Live Text selection is handled in a later task
        }
        needsDisplay = true
    }

    /// Begin a hand/right-drag pan from `win` (WINDOW space). With a focus set,
    /// the drag repositions the focus over the image (an edit, `isEdit`); with
    /// none, it scrolls the view.
    private func beginImagePan(atWindowPoint win: CGPoint) {
        let startFocus = state.focusRect
        panStartFocus = startFocus
        interactionMode = .imagePanning(lastWin: win, startFocus: startFocus,
                                        isEdit: startFocus != nil)
        NSCursor.closedHand.set()
    }

    /// Continue an image-pan for `event`. The focus reposition delta is measured
    /// between the previous and current WINDOW points, both converted under the
    /// CURRENT scroll offset — so the async focus re-center (which scrolls the
    /// clip view between events) cancels out instead of leaking into the delta
    /// and lurching. The no-focus view pan scrolls the enclosing scroll view by
    /// the raw mouse motion (`event.delta*`), clamped by the clip view.
    private func forwardImagePanDrag(with event: NSEvent) {
        guard case .imagePanning(let lastWin, let startFocus, let isEdit) = interactionMode else { return }
        let curWin = event.locationInWindow
        if isEdit, state.focusRect != nil {
            let bounds = CGRect(origin: .zero, size: currentImageSize())
            // Convert BOTH window points with the current mapping so the
            // inter-event scroll re-center cancels (scroll-invariant delta).
            let lastImg = imagePoint(forViewPoint: convert(lastWin, from: nil))
            let curImg = imagePoint(forViewPoint: convert(curWin, from: nil))
            let delta = CGPoint(x: curImg.x - lastImg.x, y: curImg.y - lastImg.y)
            let newFocus = pannedFocus(start: state.focusRect ?? .zero,
                                       dragDeltaImage: delta, within: bounds)
            // Move the focus AND re-center at the current zoom synchronously,
            // suppressing the async re-fit (no zoom reset, no shake).
            (enclosingScrollView as? EditorCanvasScrollView)?.setFocusDuringPan(newFocus)
        } else if let scrollView = enclosingScrollView {
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            // Content follows the hand: move the document opposite the motion.
            origin.x -= event.deltaX
            origin.y -= (isFlipped ? event.deltaY : -event.deltaY)
            clip.scroll(to: origin)                 // NSClipView clamps to the document
            scrollView.reflectScrolledClipView(clip)
        }
        interactionMode = .imagePanning(lastWin: curWin, startFocus: startFocus, isEdit: isEdit)
        needsDisplay = true
    }

    /// Finish an image-pan. A focus reposition commits as ONE undo step whose
    /// "before" is the pre-drag focus; a view pan has nothing to commit.
    private func endImagePan() {
        guard case .imagePanning(_, let startFocus, let isEdit) = interactionMode else { return }
        defer { interactionMode = .idle; panStartFocus = nil; baseToolCursor.set() }
        if isEdit, let startFocus, state.focusRect != startFocus {
            let finalFocus = state.focusRect
            state.focusRect = startFocus                 // restore pre-drag for the checkpoint
            state.recordUndoCheckpoint(action: "Move Focus")
            state.focusRect = finalFocus                 // re-apply (re-fit stays suppressed)
        }
        // Re-enable re-fit for future focus changes AFTER the undo mutations, so
        // their queued observe tasks still skip the re-fit (keep zoom + position).
        if isEdit { (enclosingScrollView as? EditorCanvasScrollView)?.endFocusPan() }
        needsDisplay = true
    }

    /// In the Hand tool, the scroll wheel zooms the canvas (image + focus
    /// overlay scale together via `state.zoom`) instead of scrolling. Every
    /// other tool keeps the default scroll behavior.
    override func scrollWheel(with event: NSEvent) {
        // ⌘ + scroll → continuous zoom toward the cursor (consistent for ALL
        // tools). Plain scroll (any tool, incl. Hand) scrolls/pans normally.
        if event.modifierFlags.contains(.command),
           let scroll = enclosingScrollView as? EditorCanvasScrollView {
            scroll.zoomByScroll(scrollDeltaY: event.scrollingDeltaY,
                                precise: event.hasPreciseScrollingDeltas,
                                atWindowPoint: event.locationInWindow)
            return
        }
        super.scrollWheel(with: event)
    }

    // MARK: - Right-mouse pan (any tool)

    /// Press point of an in-progress right-mouse gesture (WINDOW space), or nil.
    private var rightMouseDownWin: CGPoint?
    /// True once a right-drag has moved far enough to pan — suppresses the menu.
    private var rightDragPanned = false

    override func rightMouseDown(with event: NSEvent) {
        guard !state.isReadOnly else { super.rightMouseDown(with: event); return }
        rightMouseDownWin = event.locationInWindow
        rightDragPanned = false
        // Don't start panning yet — wait for movement so a plain right-click
        // still opens the context menu (presented in rightMouseUp).
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let downWin = rightMouseDownWin else { super.rightMouseDragged(with: event); return }
        let curWin = event.locationInWindow
        if !rightDragPanned, panDragExceedsThreshold(downWin, curWin, threshold: 3) {
            rightDragPanned = true
            beginImagePan(atWindowPoint: downWin)   // pan from the press point
        }
        if rightDragPanned { forwardImagePanDrag(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        let didPan = rightDragPanned
        rightMouseDownWin = nil
        rightDragPanned = false
        if didPan {
            endImagePan()
        } else if let menu = menu(for: event) {   // a click, not a drag → context menu
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if state.showsImageTextSearchPanel { return }
        if state.selectedTool == .textSelect {
            handleLiveTextMouseDragged(event)
            return
        }
        guard let start = dragStartImagePoint else { return }
        let viewP = convert(event.locationInWindow, from: nil)
        let current = imagePoint(forViewPoint: viewP)
        let dx = current.x - start.x
        let dy = current.y - start.y

        switch interactionMode {
        case .idle:
            break
        case .drawing:
            dragCurrent = current
            if state.selectedTool == .pen || state.selectedTool == .penArrow
                || (state.selectedTool == .blur && state.blurRegionShape == .freehand) {
                penPoints.append(current)
            }
            needsDisplay = true
        case .moving(let originals):
            let delta = CGVector(dx: dx, dy: dy)
            state.annotations = state.annotations.map { a in
                guard let original = originals[a.id] else { return a }
                return Annotation(id: a.id, geometry: translatedGeometry(original, by: delta),
                                  style: a.style, transform: a.transform)
            }
            needsDisplay = true
        case .resizing, .rotating:
            // Object resize/rotate drags are owned by SelectionChromeOverlay now
            // (screen-space). The canvas never enters these modes anymore.
            break
        case .marquee:
            marqueeCurrent = current
            state.marqueeRect = rectFromPoints(marqueeStart ?? current, current)
            needsDisplay = true
        case .focusCropping, .cropResizing, .cropMoving:
            // Focus/crop anchor drags are owned by SelectionChromeOverlay now
            // (screen-space). The canvas never enters these modes anymore.
            break
        case .imagePanning:
            forwardImagePanDrag(with: event)
        }
    }

    /// macOS COALESCES mouse-dragged events by default: a fast stroke reports a
    /// fraction of the positions the hardware actually saw, and the curve fit
    /// then has to bridge widely-spaced samples, which is what makes quick
    /// curves look faceted. Turning coalescing off for the duration of a
    /// freehand stroke is the single biggest fidelity win available here.
    ///
    /// It is an app-GLOBAL setting, so `endFinePointerSampling` must run on
    /// every exit from the stroke or the whole app keeps paying for the denser
    /// event stream.
    private func beginFinePointerSampling() {
        NSEvent.isMouseCoalescingEnabled = false
    }

    private func endFinePointerSampling() {
        NSEvent.isMouseCoalescingEnabled = true
    }

    override func mouseUp(with event: NSEvent) {
        // Unconditional: whatever the stroke did, coalescing goes back on.
        endFinePointerSampling()
        if !penPoints.isEmpty {
            PenDiag.ended(rawCount: penPoints.count, committed: true)
        }
        if state.showsImageTextSearchPanel { return }
        if state.selectedTool == .textSelect { return }
        if case .imagePanning = interactionMode {
            endImagePan()
            return
        }
        // Focus-crop anchor commit is owned by SelectionChromeOverlay now.

        defer {
            interactionMode = .idle
            dragStartImagePoint = nil
            mouseDownWindowPoint = nil
            // Redraw so a REJECTED draw (e.g. an arrow under the minimum drag)
            // clears its live preview the moment the mouse is released; the
            // next drag otherwise left the ghost arrow on screen until the next
            // click. Harmless (redundant) on committed draws.
            needsDisplay = true
        }

        switch interactionMode {
        case .moving:
            // The move already mutated state during the drag; nothing to commit.
            // Grow the image to fit if the object was dropped past the edge.
            onAnnotationSettled?()
            return
        case .idle, .resizing, .rotating, .cropResizing, .cropMoving, .imagePanning:
            // Resize / pan already mutated state (or handled by the early return
            // above); nothing to commit here.
            // (The pending crop is committed on Return, not on mouseUp.)
            return
        case .marquee:
            commitMarquee(additive: event.modifierFlags.contains(.shift)
                                 || event.modifierFlags.contains(.command))
            marqueeStart = nil
            marqueeCurrent = nil
            state.marqueeRect = nil
            needsDisplay = true
            return
        case .focusCropping:
            // Focus-crop drags live in SelectionChromeOverlay now; the canvas
            // never enters this mode. Kept for switch exhaustiveness.
            return
        case .drawing:
            // Existing 3.A flow follows below.
            break
        }

        guard let start = dragStart, let end = dragCurrent else { return }
        dragStart = nil
        dragCurrent = nil

        let imgSize = currentImageSize()
        let imageBounds = CGRect(origin: .zero, size: imgSize)
        // Annotation tools draw in the full canvas — including beyond the image
        // edge — and `onAnnotationSettled` grows the canvas to cover the result
        // on commit. Only the Crop tool stays clamped to the image (a crop must
        // live inside the source).
        let clampedStart = CGPoint(
            x: min(max(start.x, 0), imageBounds.maxX),
            y: min(max(start.y, 0), imageBounds.maxY)
        )
        let clampedEnd = CGPoint(
            x: min(max(end.x, 0), imageBounds.maxX),
            y: min(max(end.y, 0), imageBounds.maxY)
        )

        switch state.selectedTool {
        case .select, .textSelect, .hand:
            break   // neutral / live-text / pan tools create no annotation on mouseUp
        case .arrow:
            if screenDragDistance(event: event) < minArrowDragDistance { return }
            commitDrawnAnnotation(Annotation(
                geometry: .arrow(start: start, end: end),
                style: strokeCreationStyle(state: state)
            ), action: "Add Arrow")
        case .rectangle:
            let r = rectFromPoints(start, end)
            if r.width < 3 || r.height < 3 { return }
            commitDrawnAnnotation(Annotation(
                geometry: .rectangle(rect: r),
                style: shapeCreationStyle(state: state)
            ), action: "Add Rectangle")
        case .crop:
            let cropRect = cropDragRect(from: clampedStart, to: clampedEnd, bounds: imageBounds)
            // A click (no drag) outside the selection dismisses it. The Confirm
            // crop button and Return-to-crop are both gated on `pendingCrop`, so
            // they disable automatically once the selection is gone.
            if cropRect.isNull || cropRect.width < 3 || cropRect.height < 3 {
                state.pendingCrop = nil
                return
            }
            state.pendingCrop = cropRect
            window?.makeFirstResponder(self)
        case .text:
            let dragged = rectFromPoints(start, end)
            let isClick = dragged.width < 8 && dragged.height < 8
            let style = creationTextStyle()
            let rect = TextBoxSizer.creationRect(clickAt: start, draggedRect: dragged,
                                                 isClick: isClick, style: style)
            beginTextEditing(rect: rect, existingID: nil, initialRuns: [], style: style)
        case .ellipse:
            let r = rectFromPoints(start, end)
            if r.width < 3 || r.height < 3 { return }
            commitDrawnAnnotation(Annotation(
                geometry: .ellipse(rect: r),
                style: shapeCreationStyle(state: state)
            ), action: "Add Ellipse")
        case .line:
            if screenDragDistance(event: event) < minArrowDragDistance { return }
            commitDrawnAnnotation(Annotation(
                geometry: .line(start: start, end: end),
                style: strokeCreationStyle(state: state)
            ), action: "Add Line")
        case .badge:
            let dragged = rectFromPoints(start, end)
            let isClick = dragged.width < 8 && dragged.height < 8
            let radius = isClick ? state.badgeRadius : max(8, hypot(end.x - start.x, end.y - start.y))
            commitDrawnAnnotation(Annotation(
                geometry: .badge(center: start, radius: radius),
                style: badgeCreationStyle(state: state)
            ), action: "Add Step")
        case .pen:
            let path = penPoints
            penPoints = []
            // A click / tiny jitter draws nothing and clears the selection, so
            // you can click to deselect without leaving a dot behind.
            guard path.count >= 2, penPathScreenExtent(path) >= penClickThreshold else {
                state.clearSelection()
                needsDisplay = true   // clear the transient single-point preview dot
                return
            }
            // Keep the full drawn path so the committed stroke is exactly as
            // smooth as the live preview. (The old anchor-capped simplification
            // existed only to bound per-vertex handles, which the pen no longer
            // uses — it now resizes via a bounding box.)
            commitDrawnAnnotation(Annotation(
                geometry: .pen(points: path),
                style: strokeCreationStyle(state: state)
            ), action: "Draw")
        case .penArrow:
            let path = penPoints
            penPoints = []
            // A click / tiny jitter draws nothing and clears the selection.
            // needsDisplay clears the transient single-point preview dot that was
            // drawn while the mouse was down (this path returns before the
            // function's trailing needsDisplay).
            guard path.count >= 2, penPathScreenExtent(path) >= penClickThreshold else {
                state.clearSelection()
                needsDisplay = true
                return
            }
            commitDrawnAnnotation(Annotation(
                geometry: .penArrow(points: path),
                style: strokeCreationStyle(state: state)
            ), action: "Draw Arrow")
        case .blur:
            guard let region = makeBlurRegion(start: start, end: end) else { return }
            commitDrawnAnnotation(Annotation(
                geometry: .blur(region: region),
                style: blurCreationStyle(state: state)
            ), action: "Blur")
        }

        needsDisplay = true
    }

    /// Commit a freshly drawn annotation: checkpoint, append, and auto-select
    /// it so the just-drawn object is immediately editable in the object panel
    /// and shows its handles — mirroring the Text tool, which selects on commit
    /// (see `commitTextEditing`).
    /// Diagnostics (UndoDiag): compact size summary of a just-drawn geometry,
    /// so the trace shows whether a redo-clearing "edit" was a real gesture
    /// or an invisible accidental micro-drag (3px line, 1-char text…).
    private static func gestureSummary(_ g: Geometry) -> String {
        switch g {
        case let .line(s, e), let .arrow(start: s, end: e):
            return String(format: "%.1fpx (%.0f,%.0f)→(%.0f,%.0f)", hypot(e.x - s.x, e.y - s.y), s.x, s.y, e.x, e.y)
        case let .rectangle(rect: r), let .ellipse(rect: r):
            return String(format: "%.0f×%.0f", r.width, r.height)
        case let .pen(points: pts), let .penArrow(points: pts):
            return "pen \(pts.count) pts"
        case let .badge(center: _, radius: r):
            return String(format: "badge r%.0f", r)
        default:
            return String(describing: g).prefix(40).description
        }
    }

    private func commitDrawnAnnotation(_ annotation: Annotation, action: String) {
        UndoDiag.note("canvas gesture commit '\(action)' — \(Self.gestureSummary(annotation.geometry))")
        state.recordUndoCheckpoint(action: action)
        state.annotations.append(annotation)
        state.selectOnly(annotation.id)
        // The annotation may extend past the image edge (drawing is no longer
        // clamped to the image). Grow the canvas to cover it — a no-op when
        // everything already fits. The checkpoint was taken before the append,
        // so one ⌘Z reverts both the draw and the grow.
        onAnnotationSettled?()
    }

    /// Build the `BlurRegion` for the just-finished drag, per the active region
    /// shape. Returns nil for a too-small rect/ellipse or a freehand click
    /// (which should create nothing).
    /// Build the unclamped image-space crop rect for a drag from `a` to `b`.
    /// Applies the active aspect ratio (if any); otherwise returns the raw
    /// intersection with `bounds`. Used by both draw() preview and mouseUp commit.
    private func cropDragRect(from a: CGPoint, to b: CGPoint, bounds: CGRect) -> CGRect {
        let raw = rectFromPoints(a, b)
        if let ratio = state.cropAspectRatio {
            return aspectConstrainedRect(raw, aspect: ratio, anchor: a, bounds: bounds)
        }
        return raw.intersection(bounds)
    }

    private func makeBlurRegion(start: CGPoint, end: CGPoint) -> BlurRegion? {
        switch state.blurRegionShape {
        case .rect:
            let r = rectFromPoints(start, end)
            guard r.width >= 3, r.height >= 3 else { return nil }
            return .rect(r)
        case .ellipse:
            let r = rectFromPoints(start, end)
            guard r.width >= 3, r.height >= 3 else { return nil }
            return .ellipse(r)
        case .freehand:
            let path = penPoints
            penPoints = []
            guard path.count >= 2 else { return nil }
            return .freehand(points: PathSimplify.simplifiedPenPath(path), width: state.blurBrushWidth)
        }
    }

    private func commitMarquee(additive: Bool) {
        guard let a = marqueeStart, let b = marqueeCurrent else { return }
        let rect = rectFromPoints(a, b)
        let hitIDs = annotationsContained(state.annotations, rect: rect)
        let newSet: Set<UUID> = additive
            ? state.selectedAnnotationIDs.union(hitIDs)
            : Set(hitIDs)
        // A multi-selection has no object highlighted by default; a single
        // marquee'd object becomes the primary so its panel/handles show.
        let primary: UUID? = newSet.count == 1 ? newSet.first : nil
        state.setSelection(newSet, primary: primary)
    }

    /// A left-click in the gray margin around the canvas. Those clicks land on
    /// the clip view rather than this view, because the document view is
    /// smaller than the viewport whenever the image is zoomed out — the same
    /// reason right-clicks out there are forwarded for the context menu.
    ///
    /// Treated like a click on empty canvas: commit any in-progress text edit
    /// and drop the selection. Without this, clicking away from the image left
    /// everything selected, which read as the click having been ignored.
    func clearSelectionFromMargin() {
        if isEditingText { commitTextEditing() }
        state.clearSelection()
        window?.makeFirstResponder(self)
    }

    /// A mouse-down that landed in the margin. Returns true when this view has
    /// taken ownership of the drag, in which case the clip view must forward
    /// the rest of the sequence (`mouseDragged`/`mouseUp`) here too — a drag
    /// otherwise belongs to whichever view received the down event, so the
    /// canvas would see the start of a marquee and never its end.
    ///
    /// The Select tool takes it (rubber-band marquee from the margin) and so do
    /// the drawing tools (arrow/line/rect/ellipse/pen/badge/blur/text): a shape
    /// may be drawn in the margin around the image, and the canvas grows to
    /// cover it on commit. Crop must stay inside the image and the pointer tools
    /// (hand / live-text) mean a selection-clearing click, so those just drop
    /// the selection. Our `mouseDown` reads `event.locationInWindow`, so it
    /// hit-tests correctly even though the click was delivered elsewhere.
    func handleMarginMouseDown(_ event: NSEvent) -> Bool {
        let drawsInMargin = isDrawingTool && state.selectedTool != .crop
        guard state.selectedTool == .select || drawsInMargin else {
            clearSelectionFromMargin()
            return false
        }
        window?.makeFirstResponder(self)
        mouseDown(with: event)
        return true
    }

    override var acceptsFirstResponder: Bool { true }

    /// Paste annotation objects from the clipboard, anchored at the last
    /// pointer position (or centered when the pointer is outside the image).
    /// Returns true if anything was pasted. Blocked in read-only mode.
    @discardableResult
    func pasteAnnotations() -> Bool {
        guard !state.isReadOnly else { return false }
        guard let payload = AnnotationPasteboard.read(), !payload.annotations.isEmpty else { return false }
        guard let box = boundingBox(of: payload.annotations) else { return false }
        let delta = pasteTranslation(boundingBox: box,
                                     cursor: lastMouseImagePoint,
                                     imageSize: currentImageSize())
        for (id, data) in payload.assets where state.imageAssets[id] == nil {
            state.registerImageAsset(id: id, data: data)
        }
        let pasted = clonedForPaste(payload.annotations, translatedBy: delta)
        state.insertPasted(pasted)
        needsDisplay = true
        return true
    }

    // MARK: - Inline text editing

    /// True while a text box is being typed.
    var isEditingText: Bool { inlineEditor != nil }

    private func creationTextStyle() -> Style { textCreationStyle(state: state) }

    /// One run in the box's creation style. Used to seed a new (empty) text box
    /// and to measure default height; the rich editor produces real runs once
    /// the user types.
    private func creationRun(_ text: String, style: Style) -> TextRun {
        TextRun(text: text, color: style.strokeColor, fontSize: style.fontSize, isBold: style.isBold,
                fontFamily: state.textFontFamily,
                weight: state.textWeight,
                isItalic: state.textIsItalic,
                underline: state.textUnderline,
                strikethrough: state.textStrikethrough,
                highlight: state.textHighlight.map { SerializableColor(opaqueSRGB($0)) },
                outlineColor: state.textOutlineColor.map { SerializableColor(opaqueSRGB($0)) },
                outlineWidth: state.textOutlineWidth)
    }

    /// Start an inline edit session over `rect` (image space). `existingID` is
    /// nil for a freshly drawn box, or the id of an existing text box being
    /// re-edited (which is hidden from the draw loop while editing).
    private func beginTextEditing(rect: CGRect, existingID: UUID?, initialRuns: [TextRun], style: Style) {
        commitTextEditing()   // close any prior session first
        let editor = InlineTextEditor()
        inlineEditor = editor
        editingBoxRect = rect
        editingStyle = style
        editingLayoutWidth = style.effectiveTextLayoutWidth(rect: rect)
        editingRectFollowsWidth = editingLayoutWidth <= rect.width + 0.5
        state.editingAnnotationID = existingID
        editingSeedRuns = initialRuns
        didSeedEditor = false

        addSubview(editor.textView)
        let session = TextEditingSession(editor: editor)
        state.activeTextEditing = session
        editor.onSelectionChange = { [weak session] in session?.refresh() }
        editor.onChange = { [weak self] in self?.handleEditingTextChanged() }
        editor.onCommit = { [weak self] in self?.commitTextEditing() }
        repositionInlineEditor()
        window?.makeFirstResponder(editor.textView)
        needsDisplay = true
    }

    /// Re-layout the inline editor for the current scale/origin (called on
    /// begin, on text change, and on `layout()` so zoom/resize stays WYSIWYG).
    private func repositionInlineEditor() {
        guard let editor = inlineEditor, let rect = editingBoxRect, let style = editingStyle else { return }
        let scale = currentScale()
        let origin = imageDrawRect().origin
        // The text view always displays at the LAYOUT rect (full text visible
        // while editing); the mask (editingBoxRect) applies to the committed
        // render only. See handleEditingTextChanged.
        let layoutRect = CGRect(x: rect.minX, y: rect.minY, width: editingLayoutWidth, height: rect.height)
        let frame = viewRect(forImageRect: layoutRect, scale: scale, origin: origin)
        if !didSeedEditor {
            editor.configure(frame: frame, runs: editingSeedRuns, defaultRun: creationRun("", style: style),
                             opacity: style.opacity, scale: scale, wrapWidth: editingLayoutWidth * scale,
                             alignment: style.textAlignment, lineSpacing: style.lineSpacing,
                             verticalAlignment: style.textVerticalAlignment)
            didSeedEditor = true
        } else {
            editor.updateScale(scale, wrapWidth: editingLayoutWidth * scale)
            editor.textView.frame = frame
        }
    }

    private func handleEditingTextChanged() {
        guard let editor = inlineEditor, let rect = editingBoxRect else { return }
        let runs = editor.currentRuns
        let measured = runs.isEmpty ? [creationRun(" ", style: editingStyle ?? creationTextStyle())] : runs
        let grown = TextBoxSizer.grownBox(
            runs: measured, lineSpacing: editingStyle?.lineSpacing ?? 0,
            rect: rect, layoutWidth: editingLayoutWidth,
            rectFollowsWidth: editingRectFollowsWidth)
        editingBoxRect = grown.rect
        editingLayoutWidth = grown.layoutWidth
        // The text view lays out at the LAYOUT width and shows everything
        // (approved: hidden text is visible while editing; the mask applies
        // to the committed render only).
        let scale = currentScale()
        editor.updateScale(scale, wrapWidth: editingLayoutWidth * scale)
        let layoutRect = CGRect(x: grown.rect.minX, y: grown.rect.minY,
                                width: editingLayoutWidth, height: grown.rect.height)
        editor.textView.frame = viewRect(forImageRect: layoutRect, scale: scale,
                                         origin: imageDrawRect().origin)
        needsDisplay = true
    }

    /// Finish the current edit. Empty/whitespace → discard (new) or remove
    /// (existing). Otherwise commit as ONE undo checkpoint and select the box
    /// so it can be moved/resized. The active tool is left unchanged (so
    /// committing by switching tools lands on the tool the user picked).
    func commitTextEditing(reselect: Bool = true) {
        guard let editor = inlineEditor, let rect = editingBoxRect, let style = editingStyle else { return }
        let runs = editor.currentRuns
        let empty = editor.isEmpty
        let existingID = state.editingAnnotationID
        let layoutWidth = editingLayoutWidth
        // Box-level style reflects the live editor: alignment/line-spacing were
        // previewed live; vertical-align + opacity take effect on commit.
        var finalStyle = style
        finalStyle.textAlignment = editor.alignment
        finalStyle.textVerticalAlignment = editor.verticalAlignment
        finalStyle.lineSpacing = editor.lineSpacing
        finalStyle.opacity = editor.opacity

        // Remember the last-used styling BEFORE tearing down — even an empty box
        // counts: the user may have adjusted the panel then clicked away / hit
        // Esc without typing, and those tweaks must stick. Per-run values come
        // from the trailing run, or the live typing attributes when nothing was
        // typed (an empty box has no runs).
        rememberTextCreationDefaults(run: runs.last ?? editor.currentTypingRun, boxStyle: finalStyle)

        // Tear down the overlay first.
        editor.textView.removeFromSuperview()
        if window?.firstResponder == editor.textView { window?.makeFirstResponder(self) }
        inlineEditor = nil
        editingBoxRect = nil
        editingStyle = nil
        editingLayoutWidth = 0
        editingRectFollowsWidth = true
        state.editingAnnotationID = nil
        didSeedEditor = false
        state.activeTextEditing = nil

        if empty {
            if let id = existingID {
                state.recordUndoCheckpoint(action: "Delete Text")
                state.annotations.removeAll { $0.id == id }
                state.clearSelection()
            }
            // New empty box: discard silently (no checkpoint, no annotation).
            needsDisplay = true
            return
        }

        let finalHeight = textBoxHeight(runs: runs, width: layoutWidth, lineSpacing: finalStyle.lineSpacing)
        let finalRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                               height: max(rect.height, finalHeight))
        finalStyle.textLayoutWidth = layoutWidth > finalRect.width + 0.5 ? layoutWidth : nil
        UndoDiag.note("text commit \(existingID == nil ? "NEW" : "edit") — "
            + "\(runs.map(\.text).joined().count) chars, rect \(Int(finalRect.width))×\(Int(finalRect.height))")
        state.recordUndoCheckpoint(action: existingID == nil ? "Add Text" : "Edit Text")
        if let id = existingID, let idx = state.annotations.firstIndex(where: { $0.id == id }) {
            state.annotations[idx] = Annotation(id: id, geometry: .text(rect: finalRect, runs: runs),
                                                style: finalStyle, transform: state.annotations[idx].transform)
            if reselect { state.selectOnly(id) }
        } else {
            let annotation = Annotation(geometry: .text(rect: finalRect, runs: runs), style: finalStyle)
            state.annotations.append(annotation)
            if reselect { state.selectOnly(annotation.id) }
        }
        // A text box can extend past the image edge (created in the margin, or
        // grown while typing) — grow the canvas to fit it on commit.
        onAnnotationSettled?()
        needsDisplay = true
    }

    /// Persist the just-used text styling as the Text tool's creation defaults so
    /// the next new box inherits it. Paragraph defaults are plain (text-only)
    /// vars; color and opacity route through the per-tool stores via
    /// `rememberTextToolStyle` so they land in the Text tool's slot without
    /// repainting a tool the commit may have switched to. Called for every
    /// commit — including empty boxes — so panel-only tweaks are remembered.
    private func rememberTextCreationDefaults(run r: TextRun, boxStyle: Style) {
        state.textAlignment = boxStyle.textAlignment
        state.textVerticalAlignment = boxStyle.textVerticalAlignment
        state.textLineSpacing = boxStyle.lineSpacing
        state.rememberTextToolStyle(color: r.color.nsColor, opacity: boxStyle.opacity)
        state.textFontSize = r.fontSize
        state.textIsBold = r.isBold
        state.textFontFamily = r.fontFamily
        AnnotationTextFont.remembered = r.fontFamily
        state.textWeight = r.weight
        state.textIsItalic = r.isItalic
        state.textUnderline = r.underline
        state.textStrikethrough = r.strikethrough
        state.textHighlight = r.highlight?.nsColor
        state.textOutlineColor = r.outlineColor?.nsColor
        state.textOutlineWidth = r.outlineWidth
    }

    /// Begin re-editing an existing text annotation by id.
    private func beginEditingExisting(_ id: UUID) {
        guard let a = state.annotations.first(where: { $0.id == id }),
              case let .text(rect, runs) = a.geometry else { return }
        beginTextEditing(rect: rect, existingID: id, initialRuns: runs, style: a.style)
    }

    /// Route a key event to the inline editor while typing. Returns true if
    /// consumed. Typing keys / Return are NOT consumed (return false) so the
    /// text view handles them normally via keyDown.
    func handleKeyWhileEditingText(_ event: NSEvent) -> Bool {
        guard let editor = inlineEditor else { return false }
        // Esc commits.
        if event.keyCode == 53 {
            commitTextEditing()
            return true
        }
        guard event.modifierFlags.contains(.command) else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option])
        switch (event.charactersIgnoringModifiers ?? "", mods) {
        case ("z", [.command]):                       editor.performUndo();  return true
        case ("z", [.command, .shift]), ("Z", [.command, .shift]): editor.performRedo(); return true
        case ("a", [.command]):                       editor.selectAllText(); return true
        case ("c", [.command]):                       editor.copyText();     return true
        case ("x", [.command]):                       editor.cutText();      return true
        case ("v", [.command]):                       editor.pasteText();    return true
        case ("s", [.command]):                       commitTextEditing();   return true
        default:                                       return false
        }
    }

    override func layout() {
        super.layout()
        repositionInlineEditor()
        // The zoom filters depend on the settled frame, so re-pick them here.
        applyMagnificationFilter()
    }

    /// AppKit assigns `layer.contentsScale = window.backingScaleFactor` here,
    /// which discards the zoom-aware density (`canvasRasterScale`). Without
    /// this override the canvas rasterised at plain backing scale from window
    /// attachment until the next explicit zoom — the first view of a capture
    /// looked soft, then snapped sharp after any zoom, and stayed sharp.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyMagnificationFilter()
    }

    override func keyDown(with event: NSEvent) {
        if state.showsImageTextSearchPanel, event.keyCode == 53 {
            state.userSelectedTool(.select)
            return
        }
        if state.selectedTool == .textSelect, event.keyCode == 53 {   // Esc
            ocrSelection = .collapsed(at: TextPosition(line: 0, char: 0))
            needsDisplay = true
            state.escapeToInfo()
            return
        }
        // Pending-crop has highest priority: Return commits, Esc abandons.
        if state.pendingCrop != nil {
            if event.keyCode == 36 || event.keyCode == 76 {
                if let onCommitCrop { onCommitCrop() } else { state.commitCrop() }
            } else if event.keyCode == 53 {
                state.abandonCrop()
            } else {
                super.keyDown(with: event)
            }
            needsDisplay = true
            return
        }
        // Esc dismisses an in-progress smart-redaction review before any
        // selection/tool fallback — it's the most modal thing on screen.
        if event.keyCode == 53, case .found = state.redactionScan {
            state.redactionFocusID = nil
            state.cancelRedactionScan()
            needsDisplay = true
            return
        }
        // Esc (53): deselect if something is selected, else fall back to file
        // Info (the 'i' pill), not a tool.
        if event.keyCode == 53 {
            if state.selectedAnnotationID != nil {
                state.selectedAnnotationID = nil
            } else {
                state.escapeToInfo()
            }
            needsDisplay = true
            return
        }
        // Backspace (51) or Forward-Delete (117) removes the selected
        // annotations. Blocked in read-only mode (Deleted-folder files).
        if (event.keyCode == 51 || event.keyCode == 117),
           !state.selectedAnnotationIDs.isEmpty, !state.isReadOnly {
            state.deleteSelected()
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Live Text (OCR)

    /// The exact image the canvas displays: the active base, cropped to the
    /// committed crop. OCR runs on this so recognized boxes normalize straight
    /// onto `currentImageSize()`.
    private func currentDisplayedImage() -> CGImage {
        let base = state.displayBase
        guard let crop = state.croppedRect else { return base }
        // Viewport may overhang the source (a grown canvas) → transparent there.
        return CanvasExpander.viewportBase(from: base, crop: crop,
                                           contentClip: state.contentClip, baseScale: state.displayScale)
    }

    /// Session-wide cache key for the current base, or nil for an unsaved
    /// scratch canvas — with no file there is nothing stable to key on, and
    /// its pixels can change under the same identity.
    private func sharedLayoutKey(for image: CGImage) -> TextLayoutKey? {
        guard let url = state.sourceURL else { return nil }
        return TextLayoutCache.key(
            sourceURL: url,
            baseSize: CGSize(width: image.width, height: image.height),
            showingEnhanced: state.showingEnhanced,
            showingCutout: state.showingCutout,
            croppedRect: state.croppedRect)
    }

    private func ocrKey() -> String {
        let c = state.croppedRect.map { "\($0)" } ?? "full"
        return "\(ObjectIdentifier(state.displayBase))-\(state.showingEnhanced)-\(c)"
    }

    /// Start recognition if the cache is stale. Called when the .textSelect
    /// tool becomes active and when the base image changes while it is active.
    private func ensureRecognition() {
        // A Live Text read waiting on its enhanced base must not read the base
        // being replaced: the pass would be thrown away with those pixels, and
        // its progress overlay would sit on screen next to the enhancer's.
        // Cleared when the base lands (or the attempt ends) — and since this
        // flag is observed, that clearing brings us straight back here.
        guard !state.liveTextAwaitingEnhancement else { return }
        let key = ocrKey()
        // Already have the layout for this exact base, or a recognition for it
        // is already in flight — unrelated state changes must not restart it.
        if ocrSourceKey == key && (ocrLayout != nil || isRecognizing) {
            if state.selectedTool == .textSelect,
               !state.showsImageTextSearchPanel { ensureBarcodeRecognition() }
            return
        }
        ocrTask?.cancel()
        cancelBarcodeRecognition(clearResults: true)
        ocrLayout = nil
        ocrSelection = .collapsed(at: TextPosition(line: 0, char: 0))
        ocrSourceKey = key
        let image = currentDisplayedImage()
        if state.selectedTool == .textSelect, !state.showsImageTextSearchPanel {
            ensureBarcodeRecognition(image: image, key: key)
        }

        // Reuse a layout already computed for these pixels — earlier in this
        // session, or in an earlier session via the capture's package. Without
        // it, switching captures and back (or simply relaunching) redoes ~10s
        // of Vision work on a Mac with no Neural Engine. Barcodes are still
        // detected above; only the text layout is reused.
        //
        // Checked BEFORE anything announces a recognition. Declaring one and
        // then returning early left the canvas showing "Recognizing text…"
        // forever and the Find in Image panel stuck on "waiting for image
        // scan" — the work that clears both lives in the task below, which a
        // reused layout never reaches. Nothing has started, so nothing should
        // say it has.
        let sharedKey = sharedLayoutKey(for: image)
        if let sharedKey, let cached = TextLayoutCache.shared.layout(for: sharedKey) {
            ocrLayout = cached
            isRecognizing = false
            state.liveTextHasText = !cached.isEmpty
            if cached.isEmpty, state.selectedTool == .textSelect,
               !state.showsImageTextSearchPanel {
                onLiveTextEmpty?()
            }
            recomputeImageTextSearch(resetActive: true)
            needsDisplay = true
            return
        }

        isRecognizing = true
        state.liveTextHasText = nil   // unknown until this pass completes
        if state.showsImageTextSearchPanel { publishImageTextSearchStatus(.recognizing) }
        onLiveTextRecognitionChanged?(state.liveTextProgressLabel)
        needsDisplay = true

        ocrTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Only the current task owns isRecognizing/ocrTask. If a newer
                // recognition (different key) superseded us, leave its state alone.
                if self.ocrSourceKey == key {
                    self.isRecognizing = false
                    self.ocrTask = nil
                    self.onLiveTextRecognitionChanged?(nil)
                }
                self.needsDisplay = true
            }
            do {
                let layout = try await self.textRecognizer.recognize(image)
                guard self.ocrSourceKey == key else { return }   // superseded
                if let sharedKey { TextLayoutCache.shared.store(layout, for: sharedKey) }
                self.ocrLayout = layout
                self.state.liveTextHasText = !layout.isEmpty
                // Report "no text" once per recognition via a window-level toast
                // (the controller shows it in the non-magnified host, so it's
                // readable at any zoom/resolution — unlike a canvas-drawn badge).
                if layout.isEmpty, self.state.selectedTool == .textSelect,
                   !self.state.showsImageTextSearchPanel {
                    self.onLiveTextEmpty?()
                }
                self.recomputeImageTextSearch(resetActive: true)
            } catch {
                // Cancelled or failed — leave layout nil; barcodes still detected below.
                if self.state.showsImageTextSearchPanel {
                    self.publishImageTextSearchStatus(.noText)
                }
            }
        }
    }

    private func cancelRecognition() {
        ocrTask?.cancel()
        ocrTask = nil
        isRecognizing = false
        onLiveTextRecognitionChanged?(nil)
        cancelBarcodeRecognition(clearResults: false)
        QRPayloadPopover.dismiss()
    }

    /// Cancel an in-flight Live Text read from the overlay's Cancel button.
    /// The controller owns that overlay, so it needs a way in.
    func cancelLiveTextRecognition() { cancelRecognition() }

    private func ensureBarcodeRecognition(image: CGImage? = nil, key: String? = nil) {
        guard state.selectedTool == .textSelect,
              !state.showsImageTextSearchPanel else { return }
        let sourceKey = key ?? ocrKey()
        guard barcodeSourceKey != sourceKey else { return }
        barcodeTask?.cancel()
        barcodeSourceKey = sourceKey
        let sourceImage = image ?? currentDisplayedImage()
        barcodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let barcodes = await self.barcodeRecognizer.recognize(sourceImage)
            guard !Task.isCancelled, self.barcodeSourceKey == sourceKey else { return }
            self.ocrBarcodes = barcodes
            self.barcodeTask = nil
            self.needsDisplay = true
        }
    }

    private func cancelBarcodeRecognition(clearResults: Bool) {
        let wasRunning = barcodeTask != nil
        barcodeTask?.cancel()
        barcodeTask = nil
        if clearResults || wasRunning { barcodeSourceKey = nil }
        if clearResults { ocrBarcodes = [] }
    }

    // MARK: Live Text public API (used by the controller)

    /// The selected recognized text, or "" if none.
    var selectedTextForCopy: String {
        guard let layout = ocrLayout else { return "" }
        return layout.text(for: ocrSelection)
    }

    /// Select all recognized text (for ⌘A / "Copy All Text").
    func selectAllText() {
        guard let layout = ocrLayout, !layout.isEmpty else { return }
        ocrSelection = layout.fullSelection
        needsDisplay = true
    }

    // MARK: Live Text coordinate helpers

    /// Convert a view point to normalized layout space (image space / image size).
    private func ocrNormalizedPoint(forViewPoint p: CGPoint) -> CGPoint {
        let img = currentImageSize()
        let ip = imagePoint(forViewPoint: p)
        return CGPoint(x: ip.x / img.width, y: ip.y / img.height)
    }

    /// Keep the shared OCR cache in sync with whichever OCR-backed mode is
    /// active. Leaving both Live Text and Find cancels in-flight work but keeps
    /// the completed layout cached for a fast return.
    private func handleOCRModeState() {
        if state.selectedTool == .textSelect || state.showsImageTextSearchPanel {
            if state.showsImageTextSearchPanel {
                cancelBarcodeRecognition(clearResults: false)
            }
            ensureRecognition()
            if state.showsImageTextSearchPanel {
                ocrSelection = .collapsed(at: TextPosition(line: 0, char: 0))
                recomputeImageTextSearch(resetActive: false)
            } else {
                clearImageTextSearch()
            }
        } else {
            cancelRecognition()
            ocrSelection = .collapsed(at: TextPosition(line: 0, char: 0))
            clearImageTextSearch()
            QRPayloadPopover.dismiss()
        }
    }

    /// Move the active Find result cyclically and reveal it without changing
    /// the user's zoom. Called by the sidebar Previous/Next controls.
    func moveImageTextSearchResult(by delta: Int) {
        guard state.showsImageTextSearchPanel, !imageTextSearchMatches.isEmpty else { return }
        activeImageTextSearchMatch =
            (activeImageTextSearchMatch + delta + imageTextSearchMatches.count)
            % imageTextSearchMatches.count
        publishImageTextSearchStatus(.matches(
            current: activeImageTextSearchMatch,
            total: imageTextSearchMatches.count))
        needsDisplay = true
        revealActiveImageTextSearchMatch()
    }

    private func recomputeImageTextSearch(resetActive: Bool) {
        guard state.showsImageTextSearchPanel else {
            clearImageTextSearch()
            return
        }
        let focus = normalizedImageTextSearchFocusRect()
        let query = state.imageTextSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestKey = "\(query)|\(state.imageTextSearchScope)|\(String(describing: focus))"
        let requestChanged = imageTextSearchRequestKey != requestKey
        imageTextSearchRequestKey = requestKey

        guard let layout = ocrLayout else {
            imageTextSearchMatches = []
            publishImageTextSearchStatus(.recognizing)
            needsDisplay = true
            return
        }
        guard imageTextSearchScanCanFinish else {
            imageTextSearchMatches = []
            activeImageTextSearchMatch = 0
            publishImageTextSearchStatus(.recognizing)
            needsDisplay = true
            return
        }
        if !state.imageTextSearchScanStage.isReady {
            state.imageTextSearchScanStage = .ready
        }
        guard !query.isEmpty else {
            imageTextSearchMatches = []
            activeImageTextSearchMatch = 0
            publishImageTextSearchStatus(.idle)
            needsDisplay = true
            return
        }
        guard !layout.isEmpty else {
            imageTextSearchMatches = []
            publishImageTextSearchStatus(.noText)
            needsDisplay = true
            return
        }

        imageTextSearchMatches = findImageTextMatches(
            in: layout,
            query: query,
            scope: state.imageTextSearchScope,
            normalizedFocusRect: focus)
        if resetActive || requestChanged { activeImageTextSearchMatch = 0 }
        if imageTextSearchMatches.isEmpty {
            activeImageTextSearchMatch = 0
            publishImageTextSearchStatus(.noMatches)
        } else {
            activeImageTextSearchMatch = min(activeImageTextSearchMatch,
                                              imageTextSearchMatches.count - 1)
            publishImageTextSearchStatus(.matches(
                current: activeImageTextSearchMatch,
                total: imageTextSearchMatches.count))
            if resetActive || requestChanged {
                DispatchQueue.main.async { [weak self] in
                    self?.revealActiveImageTextSearchMatch()
                }
            }
        }
        needsDisplay = true
    }

    /// A preliminary raw OCR result must not reveal the fields while Live Text
    /// is still deciding on or generating an enhanced base. If enhancement
    /// fails/cancels, fall back to the completed raw layout instead of leaving
    /// Search stuck behind the waiting panel.
    private var imageTextSearchScanCanFinish: Bool {
        switch state.imageTextSearchScanStage {
        case .waitingForEnhancementDecision:
            return false
        case .waitingForEnhancedOCR:
            if state.showingEnhanced, state.enhancedImage != nil { return true }
            if !state.enhanceRunning, state.enhancedImage == nil {
                state.imageTextSearchScanStage = .recognizingCurrentBase
                return true
            }
            return false
        case .recognizingCurrentBase, .ready:
            return true
        }
    }

    private func clearImageTextSearch() {
        guard !imageTextSearchMatches.isEmpty || imageTextSearchRequestKey != nil
                || state.imageTextSearchStatus != .idle else { return }
        imageTextSearchMatches = []
        activeImageTextSearchMatch = 0
        imageTextSearchRequestKey = nil
        publishImageTextSearchStatus(.idle)
        needsDisplay = true
    }

    private func publishImageTextSearchStatus(_ status: ImageTextSearchStatus) {
        guard state.imageTextSearchStatus != status else { return }
        state.imageTextSearchStatus = status
        onImageTextSearchStatusChanged?(status)
    }

    private func normalizedImageTextSearchFocusRect() -> CGRect? {
        guard let focus = state.focusWorkingRect ?? state.focusRect else { return nil }
        let size = currentImageSize()
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: focus.minX / size.width, y: focus.minY / size.height,
                      width: focus.width / size.width, height: focus.height / size.height)
    }

    private func revealActiveImageTextSearchMatch() {
        guard imageTextSearchMatches.indices.contains(activeImageTextSearchMatch) else { return }
        let match = imageTextSearchMatches[activeImageTextSearchMatch]
        let imageRect = imageTextSearchImageRect(for: match)
        let rect = viewRect(forImageRect: imageRect, scale: currentScale(),
                            origin: imageDrawRect().origin)
        // A partial intersection is not enough: the highlight in particular can
        // be clipped by the bottom edge while still counting as "visible".
        // Keep a stable view-space margin around every navigated result.
        guard imageTextSearchNeedsReveal(highlightRect: rect, visibleRect: visibleRect) else { return }
        glideScroll(toReveal: imageTextSearchRevealRect(for: rect))
    }

    private func drawImageTextSearch(scale: CGFloat, origin: CGPoint) {
        guard state.imageTextSearchScanStage.isReady,
              imageTextSearchMatches.indices.contains(activeImageTextSearchMatch) else { return }
        let rects = imageTextSearchMatches.map(imageTextSearchImageRect(for:))
        for (index, rect) in rects.enumerated() where index != activeImageTextSearchMatch {
            drawRedactionProposal(rect, kept: true, focused: false,
                                  scale: scale, origin: origin)
        }

        let active = rects[activeImageTextSearchMatch]
        let activeView = viewRect(forImageRect: active, scale: scale, origin: origin)
        let dim = NSBezierPath(rect: imageDrawRect())
        dim.append(NSBezierPath(rect: activeView.insetBy(dx: -3, dy: -3)).reversed)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(spotlightMaxAlpha).setFill()
        dim.fill()
        drawRedactionProposal(active, kept: true, focused: true,
                              scale: scale, origin: origin)
    }

    /// Use the same OCR-character-box → padded image-space mapping as Smart
    /// Redaction. Search previously sliced a whole-line quad by character count,
    /// which drifts badly across proportional text and wide whitespace.
    private func imageTextSearchImageRect(for match: ImageTextSearchMatch) -> CGRect {
        DetectionGeometry.imageRect(fromNormalized: match.bounds,
                                    imageSize: currentImageSize(), padding: 4)
    }

    private func drawLiveText(scale: CGFloat, origin: CGPoint) {
        let img = currentImageSize()
        if let layout = ocrLayout {
            // Always-on outline around every recognized line, so the user can see
            // what OCR captured (and spot what it missed). Green keeps it distinct
            // from the accent-blue selection fill drawn on top.
            NSColor.systemGreen.withAlphaComponent(0.9).setStroke()
            for line in layout.lines {
                let path: NSBezierPath
                if let quad = line.quad {
                    // Tilt-following outline that hugs the (tightened) text quad,
                    // so slanted text gets a slanted box, not a too-tall upright
                    // one. No inset — the quad is already tightened upstream.
                    path = quadPath(quad, imageSize: img, scale: scale, origin: origin)
                } else {
                    let vr = viewRectForNormalized(line.box, imageSize: img, scale: scale, origin: origin)
                        .insetBy(dx: -1.5, dy: -1.5)
                    path = NSBezierPath(roundedRect: vr, xRadius: 3, yRadius: 3)
                }
                path.lineWidth = 1.5
                path.stroke()
            }
            // Selection fill on top. Accumulate into a single path and fill once:
            // overlapping/adjacent regions (dense or multi-column layouts) would
            // otherwise stack their 30% alpha into dark bands. One path + nonzero
            // winding = uniform translucency. Prefer tilted span quads (carved
            // from each line's quad → follows the tilt, stays inside the outline);
            // fall back to axis-aligned rects for quad-less (synthetic) layouts.
            let selectionPath = NSBezierPath()
            let selQuads = layout.quads(for: ocrSelection)
            if !selQuads.isEmpty {
                for q in selQuads {
                    selectionPath.append(quadPath(q, imageSize: img, scale: scale, origin: origin))
                }
            } else {
                for nbox in layout.boxes(for: ocrSelection) {
                    selectionPath.appendRect(viewRectForNormalized(nbox, imageSize: img, scale: scale, origin: origin))
                }
            }
            if !selectionPath.isEmpty {
                Theme.accentColor.withAlphaComponent(0.30).setFill()
                selectionPath.fill()
            }
            // "No text found" is surfaced as a window-level toast (onLiveTextEmpty)
            // when recognition completes — not drawn here, where canvas
            // magnification would shrink it on high-resolution images.
        }
        // While `isRecognizing`, progress is the controller's shared canvas
        // overlay (see onLiveTextRecognitionChanged) — the same one Smart
        // Redaction and Extract Data use, so the card, font and Cancel button
        // match by construction rather than by hand-matched constants. It is
        // pinned to canvasHost, so unlike the badge it never needs dividing by
        // the canvas magnification.
        drawBarcodes(scale: scale, origin: origin)
    }

    /// Outline + badge for each detected QR/barcode (image-space, like the OCR
    /// line outlines). Orange distinguishes codes from the green text outlines.
    private func drawBarcodes(scale: CGFloat, origin: CGPoint) {
        guard !ocrBarcodes.isEmpty else { return }
        let img = currentImageSize()
        for code in ocrBarcodes {
            let outline: NSBezierPath
            if let quad = code.quad {
                outline = quadPath(quad, imageSize: img, scale: scale, origin: origin)
            } else {
                let vr = viewRectForNormalized(code.box, imageSize: img, scale: scale, origin: origin)
                    .insetBy(dx: -1.5, dy: -1.5)
                outline = NSBezierPath(roundedRect: vr, xRadius: 4, yRadius: 4)
            }
            NSColor.systemOrange.withAlphaComponent(0.95).setStroke()
            outline.lineWidth = 2
            outline.stroke()

            // Badge at the box's top-right corner: a filled rounded square with a
            // link/qr glyph, signalling the code is clickable.
            let vr = viewRectForNormalized(code.box, imageSize: img, scale: scale, origin: origin)
            let badgeSide: CGFloat = 22
            let badge = CGRect(x: vr.maxX - badgeSide / 2, y: vr.minY - badgeSide / 2,
                               width: badgeSide, height: badgeSide)
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            let symbolName = code.openableURL != nil ? "link" : "qrcode"
            if let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                let tinted = glyph.withSymbolConfiguration(cfg)
                NSColor.white.set()
                let gsize: CGFloat = 13
                let grect = CGRect(x: badge.midX - gsize / 2, y: badge.midY - gsize / 2,
                                   width: gsize, height: gsize)
                tinted?.draw(in: grect, from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
        }
    }

    /// Closed view-space polygon through a normalized text quad's four corners.
    private func quadPath(_ q: TextQuad, imageSize img: CGSize,
                          scale: CGFloat, origin: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        let pts = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft]
            .map { viewPointForNormalized($0, imageSize: img, scale: scale, origin: origin) }
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.close()
        return path
    }

    /// Map a normalized [0,1] top-left point (OCR layout space) to view space.
    private func viewPointForNormalized(_ p: CGPoint, imageSize img: CGSize,
                                        scale: CGFloat, origin: CGPoint) -> CGPoint {
        viewPoint(forImagePoint: CGPoint(x: p.x * img.width, y: p.y * img.height),
                  scale: scale, origin: origin)
    }

    /// Map a normalized [0,1] top-left rect (OCR layout space) to view space.
    private func viewRectForNormalized(_ nbox: CGRect, imageSize img: CGSize,
                                       scale: CGFloat, origin: CGPoint) -> CGRect {
        let imageRect = CGRect(x: nbox.minX * img.width, y: nbox.minY * img.height,
                               width: nbox.width * img.width, height: nbox.height * img.height)
        return viewRect(forImageRect: imageRect, scale: scale, origin: origin)
    }

    private func handleLiveTextMouseDown(_ event: NSEvent) {
        let viewP = convert(event.locationInWindow, from: nil)
        let bp = ocrNormalizedPoint(forViewPoint: viewP)
        if let code = ocrBarcodes.first(where: { ($0.quad?.contains(bp) ?? $0.box.contains(bp)) }) {
            // Anchor the popover to the code's view rect using the same scale/origin
            // that draw() uses: `let drawRect = imageDrawRect()` at line ~308, then
            // drawRect.origin is passed as origin to all drawing helpers.
            let img = currentImageSize()
            let rect = viewRectForNormalized(code.box, imageSize: img,
                                             scale: currentScale(), origin: imageDrawRect().origin)
            QRPayloadPopover.present(for: code, from: self, rect: rect)
            return
        }
        guard let layout = ocrLayout, !layout.isEmpty else { return }
        ocrDragAnchor = bp
        if event.clickCount >= 2, let word = layout.wordRange(at: bp) {
            ocrSelection = word
        } else {
            // Caret only on press; a drag turns it into a character-inclusive
            // selection (see handleLiveTextMouseDragged).
            ocrSelection = .collapsed(at: layout.position(at: bp))
        }
        needsDisplay = true
    }

    private func handleLiveTextMouseDragged(_ event: NSEvent) {
        guard let layout = ocrLayout, !layout.isEmpty else { return }
        let np = ocrNormalizedPoint(forViewPoint: convert(event.locationInWindow, from: nil))
        // Inclusive of the glyphs under both the press and the current point, so
        // dragging from before the first character includes it.
        ocrSelection = layout.dragSelection(from: ocrDragAnchor ?? np, to: np)
        needsDisplay = true
    }

    // MARK: - Hover (highlight + cursor)
    //
    // The non-magnified SelectionChromeOverlay owns the tracking area, cursor
    // feedback, and hover state. For NON-chrome points it calls back into
    // `cursorAndHover(atWindowPoint:)` below to get the tool/body cursor and the
    // body-hover id; chrome (handles/brackets) it resolves itself in screen space.

    /// Cursor + hover id for a NON-chrome point (the chrome overlay handles
    /// handles/brackets itself and calls this for everything else). `windowPoint`
    /// is the event's locationInWindow.
    func cursorAndHover(atWindowPoint windowPoint: NSPoint) -> (cursor: NSCursor, hoveredID: UUID?) {
        if suppressHoverCursor { return (.arrow, nil) }
        if state.showsImageTextSearchPanel { return (.arrow, nil) }
        if state.selectedTool == .textSelect {
            // Live Text: I-beam only over recognized text, pointing-hand over a
            // clickable QR/barcode, plain arrow over everything else.
            let np = ocrNormalizedPoint(forViewPoint: convert(windowPoint, from: nil))
            if ocrBarcodes.contains(where: { ($0.quad?.contains(np) ?? false) || $0.box.contains(np) }) {
                return (.pointingHand, nil)
            }
            if let layout = ocrLayout,
               layout.lines.contains(where: { ($0.quad?.contains(np) ?? false) || $0.box.contains(np) }) {
                return (.iBeam, nil)
            }
            return (.arrow, nil)
        }
        let viewP = convert(windowPoint, from: nil)
        lastMouseImagePoint = imagePoint(forViewPoint: viewP)
        if let editor = inlineEditor, editor.textView.frame.contains(viewP) { return (.iBeam, nil) }
        if state.isReadOnly { return (.arrow, nil) }
        let imageP = imagePoint(forViewPoint: viewP)
        if let id = hitTestAnnotations(state.annotations, at: imageP, tolerance: 6 / currentScale()),
           !(isDrawingTool && (state.annotations.first { $0.id == id }?.geometry.isImage ?? false)) {
            return (.openHand, id)
        }
        return (baseToolCursor, nil)
    }

    /// Tools that place a NEW annotation, as opposed to the Select/Hand/Live-Text
    /// pointer tools. Over an IMAGE object these draw instead of grabbing it.
    private var isDrawingTool: Bool {
        switch state.selectedTool {
        case .select, .textSelect, .hand: return false
        default: return true
        }
    }

    /// The cursor for the active tool over empty canvas: the Select tool uses
    /// the regular arrow (it's a pointer, not a drawing tool); Live Text uses
    /// the I-beam; the freehand blur brush uses a hollow ring sized to the
    /// stroke it will paint; other drawing tools use the crosshair for precise
    /// placement.
    private var baseToolCursor: NSCursor {
        switch state.selectedTool {
        case .select: return .arrow
        case .hand: return .openHand
        case .textSelect: return .iBeam
        case .blur where state.blurRegionShape == .freehand:
            return brushCursor(forDiameter:
                Self.brushCursorDiameter(brushWidth: state.blurBrushWidth, scale: currentScale()))
        case .crop: return Self.cropCursor
        default: return .crosshair
        }
    }

    /// Smallest on-screen brush-ring diameter (points). A heavily zoomed-out
    /// tiny brush would otherwise vanish, so we floor it to a visible dot.
    static let brushCursorMinDiameter: CGFloat = 6
    /// Largest brush-ring diameter (points). macOS clamps oversized cursor
    /// images, which would shift the hot spot off-center, so we cap first.
    static let brushCursorMaxDiameter: CGFloat = 240

    /// On-screen diameter (points) of the freehand-brush ring: the brush width
    /// (image space) times the current zoom, floored so a small brush stays
    /// visible and capped so an extreme zoom can't outgrow the cursor image.
    static func brushCursorDiameter(brushWidth: CGFloat, scale: CGFloat) -> CGFloat {
        min(brushCursorMaxDiameter, max(brushCursorMinDiameter, brushWidth * scale))
    }

    /// Cached ring cursor, keyed on its rounded diameter so we rebuild the
    /// NSImage only when the brush size or zoom actually changes — not on every
    /// `mouseMoved`.
    private var cachedBrushCursor: (diameter: CGFloat, cursor: NSCursor)?

    private func brushCursor(forDiameter diameter: CGFloat) -> NSCursor {
        let key = diameter.rounded()
        if let cached = cachedBrushCursor, cached.diameter == key { return cached.cursor }
        let cursor = Self.makeBrushCursor(diameter: key)
        cachedBrushCursor = (key, cursor)
        return cursor
    }

    /// A hollow ring (black over a white halo so it reads on any background)
    /// whose interior diameter equals the brush's on-screen width, with a small
    /// center dot marking the exact paint origin / hot spot.
    /// Cursor for the Crop tool: the toolbar's crop glyph (two interlocking
    /// corner brackets, matching SF Symbol "crop"), drawn with a white halo +
    /// dark core so it reads over any pixels. Hotspot at the centre. Built once.
    static let cropCursor: NSCursor = makeCropCursor()

    private static func makeCropCursor() -> NSCursor {
        // Use the SAME SF Symbol the toolbar shows ("crop") so shape, proportions
        // and orientation match exactly — just add a white halo so it stays
        // legible over any pixels.
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "crop", accessibilityDescription: "Crop")?
            .withSymbolConfiguration(cfg) else { return .crosshair }
        let sz = symbol.size

        func tinted(_ color: NSColor) -> NSImage {
            let out = NSImage(size: sz)
            out.lockFocus()
            let r = NSRect(origin: .zero, size: sz)
            symbol.draw(in: r)
            color.set()
            r.fill(using: .sourceIn)   // recolor the glyph's alpha to `color`
            out.unlockFocus()
            return out
        }
        let core = tinted(.black)
        let halo = tinted(NSColor.white.withAlphaComponent(0.95))

        let margin: CGFloat = 2
        let s = NSSize(width: ceil(sz.width) + margin * 2, height: ceil(sz.height) + margin * 2)
        let img = NSImage(size: s)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let origin = NSPoint(x: margin, y: margin)
        // Halo: the white glyph drawn at the 8 surrounding 1px offsets.
        for dx in [-1.0, 0, 1.0] {
            for dy in [-1.0, 0, 1.0] where !(dx == 0 && dy == 0) {
                halo.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy),
                          from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        core.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: s.width / 2, y: s.height / 2))
    }

    private static func makeBrushCursor(diameter: CGFloat) -> NSCursor {
        let d = max(brushCursorMinDiameter, diameter)
        let margin: CGFloat = 4                 // room for the halo + stroke width
        let s = d + margin * 2
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let mid = s / 2
        let ring = NSBezierPath(ovalIn: NSRect(x: margin, y: margin, width: d, height: d))
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.lineWidth = 3
        ring.stroke()
        NSColor.black.setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
        let dotR: CGFloat = 1
        let dot = NSBezierPath(ovalIn: NSRect(x: mid - dotR, y: mid - dotR, width: dotR * 2, height: dotR * 2))
        NSColor.black.setFill()
        dot.fill()
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: mid, y: mid))
    }

    /// Re-apply the hover cursor without waiting for a mouse-move, for state
    /// that changes the cursor while the pointer rests on the canvas — chiefly
    /// the freehand-blur brush ring resizing as the width slider moves. Guarded
    /// to the canvas's own bounds so it never hijacks the cursor while the
    /// pointer is over the inspector controls.
    private func refreshHoverCursor() {
        guard !suppressHoverCursor, let window else { return }
        let viewP = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(viewP) else { return }
        if state.selectedTool == .blur, state.blurRegionShape == .freehand {
            baseToolCursor.set()
        }
    }

    /// Cursor for a resize handle. Every handle uses the same custom
    /// double-headed arrow (a clean ↔ with no perpendicular cross-bar),
    /// rotated to the handle's axis so edges and corners share one style;
    /// arrow endpoints use a crosshair.
    /// Internal so the chrome overlay (Task 8 cursors) can reach it.
    static func resizeCursor(for handle: AnnotationHandle) -> NSCursor {
        switch handle {
        case .topLeft, .bottomRight: return diagonalNWSE
        case .topRight, .bottomLeft: return diagonalNESW
        case .top, .bottom:          return resizeVertical
        case .left, .right:          return resizeHorizontal
        case .start, .end:           return .crosshair
        case .penPoint:              return .crosshair
        case .rotate:                return .crosshair   // closest stock cursor to a rotation grab
        }
    }

    private static let resizeHorizontal = makeArrowCursor(degrees: 0)    // ↔ left/right
    private static let resizeVertical   = makeArrowCursor(degrees: 90)   // ↕ top/bottom
    private static let diagonalNESW     = makeArrowCursor(degrees: 45)   // "/" ↗↙
    private static let diagonalNWSE     = makeArrowCursor(degrees: -45)  // "\" ↖↘

    /// Draw a double-headed resize arrow — arrowheads at both ends, NO middle
    /// cross-bar — and rotate it by `degrees` about the center. Black over a
    /// white halo so it reads on any background. One base used for every resize
    /// handle so all four orientations look identical.
    private static func makeArrowCursor(degrees: CGFloat) -> NSCursor {
        let s: CGFloat = 28, inset: CGFloat = 5, mid = s / 2
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rot = NSAffineTransform()
        rot.translateX(by: mid, yBy: mid)
        rot.rotate(byDegrees: degrees)
        rot.translateX(by: -mid, yBy: -mid)
        rot.concat()

        let a = NSPoint(x: inset, y: mid)          // left tip
        let b = NSPoint(x: s - inset, y: mid)      // right tip
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: a); path.line(to: b)
        addArrowhead(to: path, tip: a, from: b)
        addArrowhead(to: path, tip: b, from: a)

        NSColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.black.setStroke()
        path.lineWidth = 2
        path.stroke()
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: mid, y: mid))
    }

    private static func addArrowhead(to path: NSBezierPath, tip: NSPoint, from other: NSPoint) {
        let dx = tip.x - other.x, dy = tip.y - other.y
        let len = max(0.001, hypot(dx, dy))
        let bx = -dx / len, by = -dy / len            // unit vector tip→other
        let barb: CGFloat = 8, ang: CGFloat = .pi / 6
        let c = cos(ang), sn = sin(ang)
        let p1 = NSPoint(x: tip.x + barb * (bx * c - by * sn), y: tip.y + barb * (bx * sn + by * c))
        let p2 = NSPoint(x: tip.x + barb * (bx * c + by * sn), y: tip.y + barb * (-bx * sn + by * c))
        path.move(to: p1); path.line(to: tip); path.line(to: p2)
    }

    // MARK: - Context menu (z-order)

    /// Capture-level actions for the right-click menu over empty image area —
    /// mirrors the strip thumbnail menu. Wired by the controller; act on the
    /// open capture (`state.sourceURL`).
    var onCopyCapture: (() -> Void)?
    var onShowCaptureInFinder: ((URL) -> Void)?
    var onShowCaptureInLibrary: ((URL) -> Void)?
    var onAddCaptureToLibrary: ((URL) -> Void)?
    var onDeleteCapture: ((URL) -> Void)?

    /// Where "Export to …" sends the open capture.
    enum CaptureExportKind { case image, video, package }
    /// Export the open capture. The controller owns the coordinators (and the
    /// playing-video case), so the canvas only names the destination.
    var onExportCapture: ((URL, CaptureExportKind) -> Void)?
    /// Whether the open capture is a video, deciding if "Export to Video…"
    /// appears at all. A closure evaluated when the menu is built, not a stored
    /// flag — a flag would go stale the moment the open capture changes.
    var isVideoCapture: (() -> Bool)?
    /// Fired when Live Text recognition completes with no text — the controller
    /// shows a window-level "No text found" toast (readable at any zoom).
    var onLiveTextEmpty: (() -> Void)?
    /// Fired when Live Text recognition starts (label to show) and finishes
    /// (nil). The controller owns the progress overlay: it lives on canvasHost,
    /// outside the zoomed canvas, so it needs no magnification compensation and
    /// can carry a real Cancel button — which a canvas-drawn badge could not.
    var onLiveTextRecognitionChanged: ((String?) -> Void)?
    /// Fired when Find in Image recognition/matching changes the sidebar's
    /// status and Previous/Next availability.
    var onImageTextSearchStatusChanged: ((ImageTextSearchStatus) -> Void)?
    /// Commit the pending crop. Wired to the controller's animated
    /// `commitCrop()` (punch-in zoom) so the Return-key / crop-to-focus paths get
    /// the same transition as the sidebar crop button. Falls back to a plain
    /// `state.commitCrop()` when unwired.
    var onCommitCrop: (() -> Void)?
    /// Discard all edits and revert to the pristine original (controller wires
    /// this to EditorWindowController.revertToOriginal).
    var onRevertToOriginal: (() -> Void)?
    /// On-device AI actions on the current capture (Summarize / Extract / Ask).
    /// Shown only where the Foundation Model is available and AI is enabled.
    var onSummarizeCapture: (() -> Void)?
    var onChatAboutCapture: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !state.isReadOnly else { return nil }
        let p = imagePoint(forViewPoint: convert(event.locationInWindow, from: nil))
        guard let hitID = hitTestAnnotations(state.annotations, at: p,
                                             tolerance: 6 / currentScale()) else {
            // Empty image area → the open capture's actions (same as the strip
            // thumbnail menu): Show in Finder, Show in Library, Delete.
            return captureMenu()
        }
        // Standard macOS behavior: right-clicking outside the current
        // selection retargets it to the hit object.
        if !state.selectedAnnotationIDs.contains(hitID) {
            state.selectedAnnotationID = hitID
        }
        return objectMenu(hitID: hitID)
    }

    /// The object right-click menu. Separated from `menu(for:)` so its
    /// structure is testable without synthesising an NSEvent.
    ///
    /// Order is the macOS convention (Keynote/Pages/Figma): clipboard, then
    /// arrange, then flip, then the destructive action last. `autoenablesItems`
    /// is false, so EVERY item sets `isEnabled` explicitly — there is no
    /// automatic validation here.
    func objectMenu(hitID: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Clipboard group. Cut/Copy/Paste go through the responder chain to
        // EditorWindow's cut:/copy:/paste:, so they reuse the same handlers
        // (and their guards) as ⌘X/⌘C/⌘V rather than duplicating the logic.
        addItem(to: menu, title: "Cut", action: #selector(cutObjects),
                key: "x", flags: [.command], enabled: true)
        addItem(to: menu, title: "Copy", action: #selector(copyObjects),
                key: "c", flags: [.command], enabled: true)
        let canPaste = AnnotationPasteboard.read() != nil || NewCanvasFactory.clipboardHasImage()
        addItem(to: menu, title: "Paste", action: #selector(pasteObjects),
                key: "v", flags: [.command], enabled: canPaste)
        addItem(to: menu, title: "Duplicate", action: #selector(duplicateObjects),
                key: "d", flags: [.command], enabled: true)

        menu.addItem(.separator())
        addZOrderItem(to: menu, title: "Bring to Front", op: .toFront,
                      action: #selector(zOrderToFront), key: "]", flags: [.command, .option])
        addZOrderItem(to: menu, title: "Bring Forward", op: .forward,
                      action: #selector(zOrderForward), key: "]", flags: [.command])
        addZOrderItem(to: menu, title: "Send Backward", op: .backward,
                      action: #selector(zOrderBackward), key: "[", flags: [.command])
        addZOrderItem(to: menu, title: "Send to Back", op: .toBack,
                      action: #selector(zOrderToBack), key: "[", flags: [.command, .option])

        // Flips — omitted entirely unless the selection has a flippable member
        // (badges never mirror — a flipped step number reads wrong), which
        // reads better than a permanently greyed pair.
        let hasFlippable = state.annotations.contains {
            state.selectedAnnotationIDs.contains($0.id) && EditorState.isFlippable($0.geometry)
        }
        if hasFlippable {
            menu.addItem(.separator())
            addItem(to: menu, title: "Flip Horizontal", action: #selector(flipHorizontal),
                    key: "", flags: [], enabled: true)
            addItem(to: menu, title: "Flip Vertical", action: #selector(flipVertical),
                    key: "", flags: [], enabled: true)
        }

        // Live Capture: write just the clicked window's original PNG. Carries
        // the assetID on the item rather than reading the selection — the
        // retarget in menu(for:) is skipped for a member of a multi-selection,
        // so the primary selection can be a different window than the one
        // clicked (see EditorState.exportableWindowAssetID).
        if let assetID = EditorState.exportableWindowAssetID(
            hit: hitID, annotations: state.annotations,
            imageAssets: state.imageAssets, isScene: !state.sceneOriginalFrames.isEmpty) {
            menu.addItem(.separator())
            let export = NSMenuItem(title: "Export This Window…",
                                    action: #selector(exportClickedWindow(_:)), keyEquivalent: "")
            export.target = self
            export.representedObject = assetID
            export.isEnabled = true
            menu.addItem(export)
        }

        menu.addItem(.separator())
        let multiple = state.selectedAnnotationIDs.count > 1
        let delete = NSMenuItem(title: multiple ? "Delete Objects" : "Delete",
                                action: #selector(deleteSelectedObjects), keyEquivalent: "\u{8}")
        delete.keyEquivalentModifierMask = []
        delete.target = self
        delete.isEnabled = true
        menu.addItem(delete)
        return menu
    }

    /// Menu item targeted at this view, with an explicit enabled state
    /// (`autoenablesItems` is off for these menus).
    private func addItem(to menu: NSMenu, title: String, action: Selector,
                         key: String, flags: NSEvent.ModifierFlags, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = flags
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // Cut/Copy/Paste are sent up the responder chain so they land on
    // EditorWindow's cut:/copy:/paste: — the same entry point as ⌘X/⌘C/⌘V,
    // including the first-responder and read-only guards inside
    // EditorWindowController. Making the canvas first responder first matters:
    // a right-click does not move focus on its own, and those handlers require
    // the canvas to hold it.
    @objc private func cutObjects() {
        guard window?.makeFirstResponder(self) == true else { return }
        NSApp.sendAction(#selector(EditorWindow.cut(_:)), to: nil, from: self)
    }
    @objc private func copyObjects() {
        guard window?.makeFirstResponder(self) == true else { return }
        NSApp.sendAction(#selector(EditorWindow.copy(_:)), to: nil, from: self)
    }
    @objc private func pasteObjects() {
        guard window?.makeFirstResponder(self) == true else { return }
        NSApp.sendAction(#selector(EditorWindow.paste(_:)), to: nil, from: self)
    }
    @objc private func duplicateObjects() {
        state.duplicateSelected()
        needsDisplay = true
    }

    @objc private func flipHorizontal() { state.flipSelected(horizontal: true) }
    @objc private func flipVertical() { state.flipSelected(horizontal: false) }
    @objc private func deleteSelectedObjects() {
        state.deleteSelected()
        needsDisplay = true
    }

    /// The background-area menu: canvas Background fill (always available, even
    /// on an unsaved blank canvas) plus — once the canvas is saved — the
    /// strip-style capture actions for the file on disk.
    /// Internal (not private) so its structure is testable without synthesising
    /// an NSEvent — same reason as `objectMenu(hitID:)`.
    func captureMenu() -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Background fill submenu — first, since it acts on the empty canvas
        // area the user just right-clicked. Works with or without a sourceURL.
        menu.addItem(backgroundFillMenuItem())
        // The rest act on the saved file; skip them for an unsaved canvas.
        guard currentCaptureURL != nil else { return menu }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy", action: #selector(captureCopy), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(captureDuplicate), keyEquivalent: "")
        duplicate.target = self
        menu.addItem(duplicate)
        menu.addItem(.separator())
        let finder = NSMenuItem(title: "Show in Finder", action: #selector(captureShowInFinder), keyEquivalent: "")
        finder.target = self
        menu.addItem(finder)
        if let url = currentCaptureURL, ScratchCapture.isScratch(url) {
            // A scratch capture isn't IN the Library, so "Show in Library"
            // would dead-end; its slot offers the keep gesture instead.
            let keep = NSMenuItem(title: "Add to Library",
                                  action: #selector(captureAddToLibrary), keyEquivalent: "")
            keep.target = self
            menu.addItem(keep)
        } else {
            let library = NSMenuItem(title: "Show in Library", action: #selector(captureShowInLibrary), keyEquivalent: "")
            library.target = self
            menu.addItem(library)
        }
        // Exports, in the strip thumbnail menu's order so the two menus read
        // alike. "Export to Video…" is OMITTED for a still capture rather than
        // greyed — the strip does the same, and a permanently dead item on
        // every screenshot is noise.
        let exportImage = NSMenuItem(title: "Export to Image",
                                     action: #selector(captureExportImage), keyEquivalent: "")
        exportImage.target = self
        menu.addItem(exportImage)
        if isVideoCapture?() == true {
            let exportVideo = NSMenuItem(title: "Export to Video…",
                                         action: #selector(captureExportVideo), keyEquivalent: "")
            exportVideo.target = self
            menu.addItem(exportVideo)
        }
        let exportPackage = NSMenuItem(title: "Export to Package…",
                                       action: #selector(captureExportPackage), keyEquivalent: "")
        exportPackage.target = self
        menu.addItem(exportPackage)
        // Focus area: crop the image down to it, or reset it to the whole
        // image. Both act on a real focus sub-region, so they're disabled when
        // the focus already equals the image size.
        menu.addItem(.separator())
        let focusEnabled = !state.focusIsFullImage
        let crop = NSMenuItem(title: "Crop to Focus Area",
                              action: #selector(cropToFocusArea), keyEquivalent: "")
        crop.target = self
        crop.isEnabled = focusEnabled
        menu.addItem(crop)
        let resetFocus = NSMenuItem(title: "Reset Focus Area",
                                    action: #selector(resetFocusArea), keyEquivalent: "")
        resetFocus.target = self
        resetFocus.isEnabled = focusEnabled
        menu.addItem(resetFocus)
        // Revert everything to the pristine original (undoable for the session).
        let revert = NSMenuItem(title: "Revert to Original Image",
                                action: #selector(revertToOriginalImage), keyEquivalent: "")
        revert.target = self
        revert.isEnabled = !state.isReadOnly && state.hasEdits
        menu.addItem(.separator())
        menu.addItem(revert)
        // Live Capture scene command — only present when this is a scene
        // (non-empty sceneOriginalFrames). Export writes the selected window's
        // PNG. (Restoring the captured layout is done by "Revert to Original
        // Image", which is scene-aware.)
        if !state.sceneOriginalFrames.isEmpty {
            let exportWindow = NSMenuItem(title: "Export Selected Window…",
                                          action: #selector(exportSelectedWindow), keyEquivalent: "")
            exportWindow.target = self
            exportWindow.isEnabled = {
                guard !state.sceneOriginalFrames.isEmpty,
                      case .image? = state.selectedAnnotation?.geometry else { return false }
                return true
            }()
            menu.addItem(exportWindow)
        }
        // Auto Arrange: repack every image object at native size into a rough
        // 16:9, non-overlapping layout, centered (canvas grows to fit). Enabled
        // with ≥2 image objects (e.g. Live Capture windows, inserted images).
        let imageCount = state.annotations.filter { $0.geometry.isImage }.count
        if !state.isReadOnly && imageCount >= 2 {
            let arrange = NSMenuItem(title: "Auto Arrange Images", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for (title, sel) in [("Auto", #selector(autoArrangeAuto)),
                                 ("Largest First", #selector(autoArrangeLargest)),
                                 ("Smallest First", #selector(autoArrangeSmallest))] {
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                item.target = self
                sub.addItem(item)
            }
            arrange.submenu = sub
            menu.addItem(arrange)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete", action: #selector(captureDelete), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    @objc private func captureCopy() { onCopyCapture?() }
    /// Duplicate the open capture (whole `.seal`, all edits) into the save
    /// folder; the recent strip / Library pick it up via their folder watch.
    @objc private func captureDuplicate() {
        guard let url = state.sourceURL else { return }
        CaptureDuplicator.duplicate([url]) { CaptureDisplayName.resolve(for: $0) }
    }
    @objc private func captureExportImage() { exportCapture(.image) }
    @objc private func captureExportVideo() { exportCapture(.video) }
    @objc private func captureExportPackage() { exportCapture(.package) }
    private func exportCapture(_ kind: CaptureExportKind) {
        if let url = state.sourceURL { onExportCapture?(url, kind) }
    }

    /// The capture the background menu acts on. A PLAYING video is the item on
    /// screen even though `sourceURL` still names the image underneath it — the
    /// video plays in an overlay rather than becoming the open document. Before
    /// this, right-clicking a recording offered actions that silently applied
    /// to whatever image had been open before it.
    private var currentCaptureURL: URL? { state.playingVideoURL ?? state.sourceURL }

    @objc private func captureShowInFinder() { if let url = currentCaptureURL { onShowCaptureInFinder?(url) } }
    @objc private func captureShowInLibrary() { if let url = currentCaptureURL { onShowCaptureInLibrary?(url) } }
    @objc private func captureAddToLibrary() { if let url = currentCaptureURL { onAddCaptureToLibrary?(url) } }
    @objc private func captureDelete() { if let url = currentCaptureURL { onDeleteCapture?(url) } }
    @objc private func summarizeCapture() { onSummarizeCapture?() }
    @objc private func chatAboutCapture() { onChatAboutCapture?() }
    @objc private func revertToOriginalImage() { onRevertToOriginal?() }

    /// Export the SELECTED window annotation's original captured image as a
    /// standalone PNG — the background-area menu, which has no clicked object
    /// to work from. No-op without a selected `.image` annotation or with a
    /// missing asset.
    @objc private func exportSelectedWindow() {
        guard case let .image(_, assetID)? = state.selectedAnnotation?.geometry,
              let png = state.imageAssets[assetID] else { return }
        saveWindowPNG(png)
    }

    /// Export the RIGHT-CLICKED window's original captured image — the object
    /// menu. The assetID rides on the menu item (see `menu(for:)`) so a
    /// multi-selection can't redirect the export to another window.
    @objc private func exportClickedWindow(_ sender: NSMenuItem) {
        guard let assetID = sender.representedObject as? String,
              let png = state.imageAssets[assetID] else { return }
        saveWindowPNG(png)
    }

    private func saveWindowPNG(_ png: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Window.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }

    @objc private func autoArrangeAuto() { arrangeImages(.auto) }
    @objc private func autoArrangeLargest() { arrangeImages(.largestFirst) }
    @objc private func autoArrangeSmallest() { arrangeImages(.smallestFirst) }

    /// Repack all image objects (`EditorState.autoArrangeImages`) then grow the
    /// canvas to fit them — reusing the move-release grow path so one ⌘Z reverts
    /// the whole rearrange + growth.
    private func arrangeImages(_ order: ArrangeOrder) {
        state.autoArrangeImages(order: order)
        onAnnotationSettled?()
        needsDisplay = true
    }

    /// Crop the image to the current focus rectangle (mirrors confirming a crop:
    /// the scroll view observes the change and refits). No-op without a focus.
    @objc private func cropToFocusArea() {
        guard let focus = state.focusRect else { return }
        state.pendingCrop = focus
        if let onCommitCrop { onCommitCrop() } else { state.commitCrop() }
        needsDisplay = true
    }

    /// Reset the focus back to the whole image (clear `focusRect`). Undoable
    /// (the checkpoint captures the current focus first, so ⌘Z restores it),
    /// mirroring how a focus move is recorded. No-op without a real focus.
    @objc private func resetFocusArea() {
        guard !state.focusIsFullImage else { return }
        state.recordUndoCheckpoint(action: "Reset Focus")
        state.focusRect = nil
        needsDisplay = true
    }

    // MARK: - Canvas background fill

    /// Named preset fills for the Background submenu — mirrors the annotation
    /// color palette (`ColorPalettePopover.presets`) so the two feel consistent.
    private static let backgroundPresets: [(name: String, color: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Blue", .systemBlue), ("Indigo", .systemIndigo),
        ("Pink", .systemPink), ("White", .white), ("Black", .black),
    ]

    /// A small filled square used as the swatch image next to a color row.
    private func swatchImage(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        let r = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        border.lineWidth = 1; border.stroke()
        image.unlockFocus()
        return image
    }

    /// The "Background" submenu: Transparent · a palette of named colors ·
    /// Custom Color… A checkmark marks the current fill (Transparent when nil;
    /// Custom when the fill matches no preset).
    private func backgroundFillMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let current = state.backgroundFill

        let transparent = NSMenuItem(title: "Transparent",
                                     action: #selector(setBackgroundTransparent), keyEquivalent: "")
        transparent.target = self
        transparent.state = (current == nil) ? .on : .off
        submenu.addItem(transparent)

        submenu.addItem(.separator())
        var matchedPreset = false
        for preset in Self.backgroundPresets {
            let serial = SerializableColor(opaqueSRGB(preset.color))
            let row = NSMenuItem(title: preset.name,
                                 action: #selector(setBackgroundPreset(_:)), keyEquivalent: "")
            row.target = self
            row.image = swatchImage(preset.color)
            row.representedObject = serial
            let isMatch = current == serial
            row.state = isMatch ? .on : .off
            if isMatch { matchedPreset = true }
            submenu.addItem(row)
        }

        submenu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom Color…",
                                action: #selector(setBackgroundCustom), keyEquivalent: "")
        custom.target = self
        custom.state = (current != nil && !matchedPreset) ? .on : .off
        submenu.addItem(custom)

        item.submenu = submenu
        return item
    }

    /// Set the canvas background fill (nil = transparent). `checkpoint` records
    /// one undo step BEFORE the change; the live color-panel drag passes false
    /// so it doesn't flood the undo stack (the checkpoint was taken on open).
    private func applyBackgroundFill(_ fill: SerializableColor?, checkpoint: Bool) {
        if checkpoint { state.recordUndoCheckpoint(action: "Background") }
        state.backgroundFill = fill
        state.markDirty()
        needsDisplay = true
    }

    @objc private func setBackgroundTransparent() { applyBackgroundFill(nil, checkpoint: true) }

    @objc private func setBackgroundPreset(_ sender: NSMenuItem) {
        guard let fill = sender.representedObject as? SerializableColor else { return }
        applyBackgroundFill(fill, checkpoint: true)
    }

    /// Open the shared color panel targeting the canvas background. One undo
    /// checkpoint is taken here; subsequent live changes update without new ones.
    @objc private func setBackgroundCustom() {
        state.recordUndoCheckpoint(action: "Background")
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = state.backgroundFill?.nsColor ?? .white
        panel.setTarget(self)
        panel.setAction(#selector(backgroundColorPanelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        // Apply the starting color immediately so a single click (no drag) sticks.
        applyBackgroundFill(SerializableColor(opaqueSRGB(panel.color)), checkpoint: false)
    }

    @objc private func backgroundColorPanelChanged(_ sender: NSColorPanel) {
        applyBackgroundFill(SerializableColor(opaqueSRGB(sender.color)), checkpoint: false)
    }

    /// An op is offered only when it would actually move the selection.
    private func addZOrderItem(to menu: NSMenu, title: String, op: ZOrderOperation,
                               action: Selector, key: String,
                               flags: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = flags
        item.target = self
        let reordered = reorderAnnotations(state.annotations,
                                           selected: state.selectedAnnotationIDs, op)
        item.isEnabled = reordered.map(\.id) != state.annotations.map(\.id)
        menu.addItem(item)
    }

    @objc private func zOrderToFront() { state.reorderSelected(.toFront) }
    @objc private func zOrderForward() { state.reorderSelected(.forward) }
    @objc private func zOrderBackward() { state.reorderSelected(.backward) }
    @objc private func zOrderToBack() { state.reorderSelected(.toBack) }

    // MARK: - File drop (insert image overlay)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !state.isReadOnly, overlayURL(from: sender) != nil else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = overlayURL(from: sender),
              let image = EditorWindowController.loadOverlayImage(from: url) else {
            return false
        }
        let viewPt = convert(sender.draggingLocation, from: nil)
        let imagePt = imagePoint(forViewPoint: viewPt)
        state.insertImageAnnotation(image, at: imagePt)
        needsDisplay = true
        return true
    }

    private func overlayURL(from sender: NSDraggingInfo) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: opts) as? [URL],
              let url = urls.first else { return nil }
        return EditorWindowController.overlayRasterExtensions
            .contains(url.pathExtension.lowercased()) ? url : nil
    }
}
