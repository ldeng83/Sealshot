import AppKit
import Observation

/// Advance a marching-ants dash phase, wrapped into [0, period). `dt` seconds;
/// the dash pattern shifts one full `period` every `loopDuration` seconds.
func cropMarchingPhase(_ current: CGFloat, dt: CGFloat, period: CGFloat, loopDuration: CGFloat) -> CGFloat {
    guard period > 0, loopDuration > 0, dt > 0 else { return current }
    let advanced = current + period * (dt / loopDuration)
    let wrapped = advanced.truncatingRemainder(dividingBy: period)
    return wrapped < 0 ? wrapped + period : wrapped
}

/// Non-magnified overlay that draws editor selection chrome at a CONSTANT
/// on-screen size, independent of zoom. It sits above the canvas scroll view,
/// pinned to the viewport, and projects EditorState geometry to screen space
/// via ChromeProjection. It also OWNS object resize/rotate hit-testing and drag
/// (screen-space hit-test, image-space math); it passes all other events through
/// (hitTest nil) so the canvas keeps select/move/draw/focus/pan. It additionally
/// OWNS cursor feedback and hover state via a tracking area covering the viewport:
/// it resolves chrome cursors (handles/brackets) itself in screen space and
/// delegates NON-chrome points to `canvas.cursorAndHover(atWindowPoint:)`.
@MainActor
final class SelectionChromeOverlay: NSView {
    private var state: EditorState
    private weak var canvas: EditorCanvasView?
    private weak var scroll: EditorCanvasScrollView?
    private var scrollObservers: [NSObjectProtocol] = []
    private var observationGeneration = 0
#if DEBUG
    private(set) var debugScrollGeometryInvalidationCount = 0
#endif

    // Constant on-screen chrome sizes (screen points — NO /zoom anywhere).
    private let handleDot: CGFloat = 8
    private let rotateDot: CGFloat = 5.5
    private let rotateOffset: CGFloat = 32

    // Focus/crop viewfinder chrome sizes (screen points — constant at any zoom).
    private let focusArm: CGFloat = 22
    private let focusTick: CGFloat = 28
    private let focusWidth: CGFloat = 3
    private let focusCornerHitRadius: CGFloat = 16
    private let focusEdgeHitTolerance: CGFloat = 10

    // Crop marquee "marching ants": the dashed crop outline animates its dash
    // phase while a crop is pending. Period = dash+gap (6+4); one loop / 0.6s.
    private let cropAntsPeriod: CGFloat = 10
    private let cropAntsLoopDuration: CGFloat = 0.6
    private var cropDashPhase: CGFloat = 0
    private var cropAntsTimer: Timer?

    // Object handle drag state. The overlay hit-tests resize/rotate handles in
    // SCREEN space (constant 12pt grab squares) and runs the drag math in IMAGE
    // space, projecting through currentProjection() each event.
    private enum HandleDrag {
        case resizing(handle: AnnotationHandle, original: Geometry, id: UUID)
        case rotating(id: UUID, center: CGPoint, startAngle: CGFloat, startTransform: AnnotationTransform)
    }
    private var handleDrag: HandleDrag?
    private var liveRotationBadge: (point: CGPoint, degrees: CGFloat)?   // image-space point

    // Focus/crop drag state. Like the object handles, hit-testing is screen-space
    // (constant grab radii) and the resize math runs in image space, projecting
    // each event through currentProjection(). Takes PRIORITY over object handles.
    private enum FocusDrag {
        case focusResizing(handle: FocusHandle, startRect: CGRect)
        case cropResizing(handle: FocusHandle, startRect: CGRect)
        case cropMoving(startRect: CGRect, grab: CGPoint)   // grab in image space
    }
    private var focusDrag: FocusDrag?

    init(state: EditorState, canvas: EditorCanvasView, scroll: EditorCanvasScrollView) {
        self.state = state
        self.canvas = canvas
        self.scroll = scroll
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        observe()
        observeScroll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
        cropAntsTimer?.invalidate()
    }

    /// Drive the crop marquee's marching-ants animation: a ~60fps timer advances
    /// the dash phase while a crop is pending, and stops (releasing the timer)
    /// otherwise — so there's no idle redraw when not cropping.
    private func startCropAnts() {
        guard cropAntsTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cropDashPhase = cropMarchingPhase(self.cropDashPhase, dt: 1.0 / 60.0,
                                                       period: self.cropAntsPeriod,
                                                       loopDuration: self.cropAntsLoopDuration)
                self.needsDisplay = true
            }
        }
        // .common so the ants keep marching during mouse tracking / scrolling.
        RunLoop.main.add(timer, forMode: .common)
        cropAntsTimer = timer
    }

    private func stopCropAnts() {
        guard cropAntsTimer != nil else { return }
        cropAntsTimer?.invalidate()
        cropAntsTimer = nil
        cropDashPhase = 0
    }

    /// Rebind all three inputs when a new image is loaded (empty→loaded or
    /// loaded→loaded swap). Re-registers observation against the new state and
    /// re-installs the scroll-bounds listener on the new scroll view.
    func rebind(state: EditorState, canvas: EditorCanvasView, scroll: EditorCanvasScrollView) {
        self.state = state
        self.canvas = canvas
        self.scroll = scroll
        observationGeneration += 1
        observe()
        observeScroll()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }   // match canvas top-left origin

    // Intercept events ONLY over a chrome handle of the primary single selection
    // or the hovered annotation (the objects whose handles are visibly drawn).
    // Everything else passes through so the canvas keeps select/move/draw/focus/pan.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        // The overlay covers the persistent host, which is wider/taller than
        // the visible clip whenever legacy scrollers claim a gutter. Chrome in
        // that gutter is neither visible canvas nor interactive canvas.
        guard currentViewportRect().contains(p) else { return nil }
        if pointerOverScroller(atWindow: convert(p, to: nil)) { return nil }
        // Find in Image is a non-editing canvas mode. Keep focus brackets
        // visible for scope context, but don't let chrome begin an edit while
        // Search owns the toolbar/sidebar.
        if state.showsImageTextSearchPanel { return nil }
        // Priority, top to bottom:
        //   1. a selected object's resize/rotate handles,
        //   2. the crop tool's own anchors (no object is selected in crop),
        //   3. an EXPLICIT focus area's brackets/edge ticks,
        //   4. a click over any object body → let the canvas select/move it,
        //   5. the full-image focus viewfinder's edge anchors.
        //
        // 3 sits above bodies because an explicit focus area is small,
        // deliberately-placed chrome — and in Live Capture it sits on top of
        // a window layer almost by definition, so letting the layer's body
        // swallow the brackets made the focus area impossible to adjust (every
        // grab dragged the layer instead). The FULL-IMAGE viewfinder (no
        // focus rect set) stays BELOW bodies: its anchors live on the canvas
        // edges/corners, and an object straddling an edge must stay grabbable.
        if selectedHandleHit(p) != nil { return self }
        if cropHit(at: p) != nil { return self }
        if state.focusRect != nil, focusViewfinderHit(at: p) != nil { return self }
        if annotationUnder(p) { return nil }
        if focusViewfinderHit(at: p) != nil { return self }
        if hoveredHandleHit(p) != nil { return self }
        return nil
    }

    /// Hit-test `p` against the full-image focus viewfinder anchors (every tool;
    /// dragging inward creates a focus region). Lower priority than object
    /// handles / bodies so an object at the canvas edge stays grabbable.
    private func focusViewfinderHit(at p: CGPoint) -> FocusDrag? {
        let proj = currentProjection()
        let v = proj.screen(fromImage: state.effectiveFocusRect)
        if let h = focusHandleHit(at: p, in: v, cornerRadius: focusCornerHitRadius, edgeTolerance: focusEdgeHitTolerance) {
            return .focusResizing(handle: h, startRect: state.effectiveFocusRect)
        }
        return nil
    }

    /// Hit-test `p` against the crop tool's pending-crop anchors, then interior
    /// move. Keeps priority (the crop tool clears object selection, so nothing
    /// competes). Nil unless the crop tool is active with a pending crop.
    private func cropHit(at p: CGPoint) -> FocusDrag? {
        guard state.selectedTool == .crop, let pending = state.pendingCrop else { return nil }
        let proj = currentProjection()
        let v = proj.screen(fromImage: pending)
        if let h = focusHandleHit(at: p, in: v, cornerRadius: focusCornerHitRadius, edgeTolerance: focusEdgeHitTolerance) {
            return .cropResizing(handle: h, startRect: pending)
        }
        if pending.contains(proj.image(fromScreen: p)) {
            return .cropMoving(startRect: pending, grab: proj.image(fromScreen: p))
        }
        return nil
    }

    /// True when `p` (screen space) is over an annotation body — so a click there
    /// selects/moves that object via the canvas rather than being captured by the
    /// full-image focus viewfinder's edge anchors when the object straddles the
    /// canvas edge.
    private func annotationUnder(_ p: CGPoint) -> Bool {
        let proj = currentProjection()
        let tolerance = 6 / max(proj.scale, 0.0001)
        return hitTestAnnotations(state.annotations, at: proj.image(fromScreen: p), tolerance: tolerance) != nil
    }

    /// Screen-space handle positions (resize dots + the rotate lollipop dot) for
    /// `annotation`, computed exactly as `drawObjectChrome` draws them. `.rotate`
    /// is appended last so resize handles win ties (mirrors `handlePositions`).
    private func screenHandles(for annotation: Annotation) -> [(AnnotationHandle, CGPoint)] {
        let proj = currentProjection()
        let b = geometryBounds(annotation.geometry)
        let center = CGPoint(x: b.midX, y: b.midY)
        let rotateM = transformMatrix(for: annotation.transform.rotationOnly, center: center)
        var handles = handlePositions(of: annotation, rotateOffset: 0)
            .filter { $0.0 != .rotate }
            .map { ($0.0, proj.screen(fromImage: $0.1)) }
        let topCenter = proj.screen(fromImage: CGPoint(x: b.midX, y: b.minY).applying(rotateM))
        let dotCenter = screenRotatePosition(topCenterScreen: topCenter, offset: rotateOffset)
        handles.append((.rotate, dotCenter))
        return handles
    }

    /// Hit-test `p` (screen space) against the SELECTED object's visibly-drawn
    /// resize/rotate handles. Highest priority, so a selected object near the
    /// canvas edge can be resized where its handles overlap the focus viewfinder.
    /// Excludes the inline-edited box (no visible chrome handles).
    private func selectedHandleHit(_ p: CGPoint) -> (id: UUID, handle: AnnotationHandle)? {
        guard state.selectedAnnotationIDs.count == 1,
              let id = state.primarySelectionID,
              id != state.editingAnnotationID,
              let annotation = state.annotations.first(where: { $0.id == id }),
              let handle = hitTestHandlePositions(screenHandles(for: annotation), at: p, handleSize: 12)
        else { return nil }
        return (id, handle)
    }

    /// Hit-test `p` against the HOVERED (unselected) object's handles. Lowest
    /// priority — the user selects the object (which then wins via
    /// `selectedHandleHit`) before its hover handles matter.
    private func hoveredHandleHit(_ p: CGPoint) -> (id: UUID, handle: AnnotationHandle)? {
        guard state.selectedAnnotationIDs.count <= 1,
              let id = state.hoveredAnnotationID,
              id != state.editingAnnotationID,
              let annotation = state.annotations.first(where: { $0.id == id }),
              !annotation.geometry.isPen,
              !annotation.geometry.isFreehandBlur,
              let handle = hitTestHandlePositions(screenHandles(for: annotation), at: p, handleSize: 12)
        else { return nil }
        return (id, handle)
    }

    override func mouseDown(with event: NSEvent) {
        if state.isReadOnly { return }
        let p = convert(event.locationInWindow, from: nil)
        // Same priority as hitTest. A body click passed through (hitTest returned
        // nil) and is handled by the canvas, so it never reaches here.
        if let (id, handle) = selectedHandleHit(p) {
            beginHandleDrag(id: id, handle: handle, at: p)
            return
        }
        if let fd = cropHit(at: p) {
            focusDrag = fd
            state.interactionInProgress = true
            return
        }
        if let fd = focusViewfinderHit(at: p) {
            focusDrag = fd
            state.focusWorkingRect = state.effectiveFocusRect
            state.interactionInProgress = true
            return
        }
        if let (id, handle) = hoveredHandleHit(p) {
            beginHandleDrag(id: id, handle: handle, at: p)
            return
        }
    }

    /// Start a resize/rotate drag on `id`'s `handle`, selecting the object if it
    /// isn't already the sole selection.
    private func beginHandleDrag(id: UUID, handle: AnnotationHandle, at p: CGPoint) {
        guard let target = state.annotations.first(where: { $0.id == id }) else { return }
        if state.primarySelectionID != id || state.selectedAnnotationIDs.count != 1 {
            state.selectOnly(id)
        }
        state.recordUndoCheckpoint(action: handle == .rotate ? "Rotate" : "Resize")
        let imageP = currentProjection().image(fromScreen: p)
        if handle == .rotate {
            let b = geometryBounds(target.geometry)
            let center = CGPoint(x: b.midX, y: b.midY)
            handleDrag = .rotating(id: id, center: center,
                                   startAngle: atan2(imageP.y - center.y, imageP.x - center.x),
                                   startTransform: target.transform)
        } else {
            handleDrag = .resizing(handle: handle, original: target.geometry, id: id)
            // Manual resize is a MASK move: freeze the layout width at drag
            // start so the live preview keeps its wrap while shrinking.
            if case .text = target.geometry { state.beginTextBoxResize(id: id) }
        }
        state.interactionInProgress = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let fd = focusDrag {
            let current = currentProjection().image(fromScreen: convert(event.locationInWindow, from: nil))
            switch fd {
            case let .focusResizing(handle, startRect):
                state.focusWorkingRect = resizeFocus(start: startRect, handle: handle, to: current,
                                                     minSize: 16, bounds: CGRect(origin: .zero, size: state.visibleImageSize))
            case let .cropResizing(handle, startRect):
                let cropBounds = CGRect(origin: .zero, size: cropBoundsSize())
                let resized = resizeFocus(start: startRect, handle: handle, to: current,
                                          minSize: 8, bounds: cropBounds)
                if let ratio = state.cropAspectRatio {
                    let anchor = cropAspectAnchor(for: handle, in: resized)
                    state.pendingCrop = aspectConstrainedRect(resized, aspect: ratio, anchor: anchor, bounds: cropBounds)
                } else {
                    state.pendingCrop = resized
                }
            case let .cropMoving(startRect, grab):
                state.pendingCrop = movedRect(startRect, by: CGPoint(x: current.x - grab.x, y: current.y - grab.y),
                                              within: CGRect(origin: .zero, size: cropBoundsSize()))
            }
            needsDisplay = true
            return
        }
        guard let drag = handleDrag else { return }
        let current = currentProjection().image(fromScreen: convert(event.locationInWindow, from: nil))
        switch drag {
        case let .resizing(handle, originalGeometry, id):
            guard let idx = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            // Rotated/flipped objects: `resizeGeometry` works in object space, so
            // inverse-map the drag point through the transform (about the ORIGINAL
            // bounds center — rotation doesn't change mid-resize).
            let transform = state.annotations[idx].transform
            var dragPoint = current
            if !transform.isIdentity {
                let b = geometryBounds(originalGeometry)
                dragPoint = current.applying(
                    transformMatrix(for: transform, center: CGPoint(x: b.midX, y: b.midY)).inverted())
            }
            // Text boxes resize FREELY under the mask model: the rect is a
            // viewport over text laid out at the frozen layout width, so
            // shrinking the height simply hides lower rows (rendering clips)
            // and shrinking the width hides trailing columns. No content-
            // height clamp here — the grow-only clamp belongs to STYLE edits
            // (a bigger font must not clip), never to manual resizing.
            let resized = resizeGeometry(originalGeometry, handle: handle, to: dragPoint,
                                         freeform: event.modifierFlags.contains(.shift))
            state.annotations[idx] = Annotation(id: id, geometry: resized,
                                                style: state.annotations[idx].style, transform: transform)
        case let .rotating(id, center, startAngle, startTransform):
            let angle = atan2(current.y - center.y, current.x - center.x)
            var degrees = startTransform.rotationDegrees + (angle - startAngle) * 180 / .pi
            // Snap to 45° multiples within 3°; ⇧ rotates freely.
            if !event.modifierFlags.contains(.shift) {
                let nearest = (degrees / 45).rounded() * 45
                if abs(degrees - nearest) <= 3 { degrees = nearest }
            }
            let normalized = normalizedDegrees(degrees)
            if let idx = state.annotations.firstIndex(where: { $0.id == id }) {
                state.annotations[idx].transform.rotationDegrees = normalized
            }
            liveRotationBadge = (point: current, degrees: normalized)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let fd = focusDrag {
            focusDrag = nil
            state.interactionInProgress = false
            if case .focusResizing = fd {
                let working = state.focusWorkingRect
                let full = CGRect(origin: .zero, size: state.visibleImageSize)
                let newFocus: CGRect? = (working?.equalTo(full) ?? false) ? nil : working
                if newFocus != state.focusRect {
                    state.recordUndoCheckpoint(action: newFocus == nil ? "Clear Focus" : "Focus")
                    state.focusRect = newFocus     // scroll view observes → fits
                }
                state.focusWorkingRect = nil
            }
            needsDisplay = true
            return
        }
        // Normalize the mask/layout coupling now that the drag settled:
        // enlarging to/past the frozen layout width re-couples, anything
        // narrower keeps the frozen width as a mask.
        if case let .resizing(_, _, id) = handleDrag,
           let annotation = state.annotations.first(where: { $0.id == id }),
           case .text = annotation.geometry {
            state.endTextBoxResize(id: id)
        }
        handleDrag = nil
        state.interactionInProgress = false
        if liveRotationBadge != nil { liveRotationBadge = nil }
        needsDisplay = true
    }

    // MARK: - Cursors + hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { applyCursorAndHover(atWindow: event.locationInWindow) }
    override func cursorUpdate(with event: NSEvent) { applyCursorAndHover(atWindow: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { setHover(nil); canvas?.clearLastMousePoint() }

    /// Resolve the cursor + hover state for the pointer, mirroring the old canvas
    /// cascade order: focus/crop brackets FIRST (priority, every tool), then object
    /// resize/rotate handles (screen space — fixes the rotated-object case), then
    /// delegate non-chrome points to the canvas for the tool/body cursor + hover.
    private func applyCursorAndHover(atWindow w: NSPoint) {
        // Short-circuit: a covering overlay (progress, video mode, lock screen) has
        // asked us to yield the arrow cursor. Doing this BEFORE the chrome checks
        // prevents focus/crop and handle paths from fighting the covering overlay.
        if canvas?.suppressHoverCursor == true { NSCursor.arrow.set(); setHover(nil); return }
        // The overlay sits ABOVE the scroll view and its tracking area covers the
        // whole bounds — including where the (overlay-style) scrollers float. Our
        // hitTest returns nil there so drags pass through to the scroller, but the
        // fall-through below would still stamp the tool cursor over it every event,
        // hiding the scroller's own arrow. Yield the arrow when over a live scroller.
        if pointerOverScroller(atWindow: w) { NSCursor.arrow.set(); setHover(nil); return }
        let p = convert(w, from: nil)
        if !currentViewportRect().contains(p) { NSCursor.arrow.set(); setHover(nil); return }
        // Mirror hitTest's priority so the cursor previews the action that a click
        // would actually perform.
        // 1) Selected object's resize/rotate handle.
        if let (id, handle) = selectedHandleHit(p) {
            EditorCanvasView.resizeCursor(for: handle).set(); setHover(id); return
        }
        // 2) Crop tool anchors / interior move.
        if let fd = cropHit(at: p) {
            switch fd {
            case let .cropResizing(handle, _): EditorCanvasView.focusResizeCursor(for: handle).set()
            case .cropMoving:                  NSCursor.openHand.set()
            case .focusResizing:               break   // cropHit never returns this
            }
            setHover(nil); return
        }
        // 3) An EXPLICIT focus area's brackets — above bodies, exactly as in
        //    hitTest: over a Live Capture layer the click resizes the focus
        //    area, so the cursor must preview that, not the layer's open hand.
        if state.focusRect != nil, let fd = focusViewfinderHit(at: p),
           case let .focusResizing(handle, _) = fd {
            EditorCanvasView.focusResizeCursor(for: handle).set(); setHover(nil); return
        }
        // 4) Object body → delegate to the canvas (body cursor + hover) so it
        //    beats the FULL-IMAGE focus viewfinder at the edges.
        if annotationUnder(p) {
            let (cursor, hoveredID) = canvas?.cursorAndHover(atWindowPoint: w) ?? (.arrow, nil)
            cursor.set(); setHover(hoveredID); return
        }
        // 5) Full-image focus viewfinder anchors.
        if let fd = focusViewfinderHit(at: p), case let .focusResizing(handle, _) = fd {
            EditorCanvasView.focusResizeCursor(for: handle).set(); setHover(nil); return
        }
        // 6) Hovered object's resize/rotate handle.
        if let (id, handle) = hoveredHandleHit(p) {
            EditorCanvasView.resizeCursor(for: handle).set(); setHover(id); return
        }
        // 7) Non-chrome → delegate to the canvas (tool/body cursor + body hover).
        let (cursor, hoveredID) = canvas?.cursorAndHover(atWindowPoint: w) ?? (.arrow, nil)
        cursor.set(); setHover(hoveredID)
    }

    /// True when the window-space pointer is over one of the scroll view's live
    /// scrollers. Asks the scroll view to hit-test its OWN subtree (which excludes
    /// this overlay, a sibling above it), so an overlay scroller that has faded out
    /// returns the content view — meaning we only yield the arrow when the scroller
    /// is actually present to interact with.
    private func pointerOverScroller(atWindow w: NSPoint) -> Bool {
        guard let scroll, let host = superview else { return false }
        let hostPoint = host.convert(w, from: nil)
        var v = scroll.hitTest(hostPoint)
        while let view = v {
            if view is NSScroller { return true }
            v = view.superview
        }
        return false
    }

    private func setHover(_ id: UUID?) {
        if state.hoveredAnnotationID != id { state.hoveredAnnotationID = id }
    }

    func currentProjection() -> ChromeProjection {
        guard let canvas else { return .identity }
        let inputs = canvas.chromeProjectionInputs()

        // Ask AppKit for three basis points rather than reconstructing its view
        // transform from scroll origin + magnification. In legacy-scroller mode
        // the clip's frame and bounds can have different sizes, adding an axis
        // scale that NSScrollView.magnification does not report.
        let origin = convert(CGPoint.zero, from: canvas)
        let xBasis = convert(CGPoint(x: 1, y: 0), from: canvas)
        let yBasis = convert(CGPoint(x: 0, y: 1), from: canvas)
        let canvasToOverlay = CGAffineTransform(
            a: xBasis.x - origin.x,
            b: xBasis.y - origin.y,
            c: yBasis.x - origin.x,
            d: yBasis.y - origin.y,
            tx: origin.x,
            ty: origin.y
        )
        return ChromeProjection(scale: inputs.scale, drawOrigin: inputs.drawOrigin,
                                canvasToScreen: canvasToOverlay)
    }

    /// The actual NSClipView viewport expressed in this overlay's coordinates.
    /// The overlay remains pinned to the persistent host so it survives image
    /// swaps; converting the clip bounds here accounts for legacy scroller
    /// gutters, borders, flipped coordinates, and any future host inset.
    func currentViewportRect() -> CGRect {
        guard let clip = scroll?.contentView else { return bounds }
        let viewport = convert(clip.bounds, from: clip).standardized
        return viewport.width > 0 && viewport.height > 0 ? viewport : bounds
    }

    private func observe() {
        let gen = observationGeneration
        withObservationTracking { [self] in
            _ = state.zoom; _ = state.selectedAnnotationIDs; _ = state.annotations
            _ = state.focusRect; _ = state.croppedRect; _ = state.pendingCrop
            _ = state.focusWorkingRect; _ = state.selectedTool
            _ = state.sidebarPanelMode
            _ = state.marqueeRect; _ = state.hoveredAnnotationID; _ = state.primarySelectionID
            _ = state.editingAnnotationID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.observationGeneration else { return }
                self.needsDisplay = true
                self.observe()
            }
        }
    }

    private func observeScroll() {
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
        scrollObservers.removeAll()
        guard let clip = scroll?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        scrollObservers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateForScrollGeometryChange() }
            }
        }
    }

    private func invalidateForScrollGeometryChange() {
#if DEBUG
        debugScrollGeometryInvalidationCount += 1
#endif
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let viewport = currentViewportRect()
        guard !viewport.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cornerRadius = scroll?.contentView.layer?.cornerRadius ?? 0
        if cornerRadius > 0 {
            NSBezierPath(roundedRect: viewport, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        } else {
            NSBezierPath(rect: viewport).addClip()
        }

        let proj = currentProjection()
        // Draw chrome for all selected annotations. Skip the one being inline-edited
        // so resize handles and the rotate lollipop do not paint over the text editor.
        for annotation in state.annotations
            where state.selectedAnnotationIDs.contains(annotation.id)
            && annotation.id != state.editingAnnotationID {
            // In a multi-selection, the primary (last clicked) is emphasized.
            let emphasized = state.selectedAnnotationIDs.count >= 2 && annotation.id == state.primarySelectionID
            drawObjectChrome(annotation, proj: proj, emphasized: emphasized)
        }
        // Hover chrome only when not multi-selecting (avoid clutter). Exclude
        // pen strokes and freehand blurs (same rules as the old canvas hover).
        // Also skip if this annotation is currently being inline-edited.
        if state.selectedAnnotationIDs.count <= 1,
           let hoveredID = state.hoveredAnnotationID,
           hoveredID != state.primarySelectionID,
           hoveredID != state.editingAnnotationID,
           let hovered = state.annotations.first(where: { $0.id == hoveredID }),
           !hovered.geometry.isPen,
           !hovered.geometry.isFreehandBlur {
            drawObjectChrome(hovered, proj: proj, emphasized: false)
        }

        // Rubber-band marquee (drag logic stays in the canvas; drawn here so the
        // outline is a constant weight at any zoom).
        if let m = state.marqueeRect {
            let r = proj.screen(fromImage: m)
            NSColor(red: 0x4A/255.0, green: 0x9E/255.0, blue: 0xFF/255.0, alpha: 1.0).setStroke()
            NSColor(red: 0x4A/255.0, green: 0x9E/255.0, blue: 0xFF/255.0, alpha: 0.12).setFill()
            let p = NSBezierPath(rect: r)
            p.fill()
            p.lineWidth = 1
            p.stroke()
        }

        // Live rotation readout — drawn last so it sits above all chrome. The
        // anchor is in image space; project it and apply the SAME constant
        // offsets/style the canvas used (overlay is flipped, like the canvas).
        if let badge = liveRotationBadge {
            let vp = currentProjection().screen(fromImage: badge.point)
            let text = "\(Int(badge.degrees.rounded()))°" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            let pad: CGFloat = 5
            let box = CGRect(x: vp.x + 14, y: vp.y - size.height - 12,
                             width: size.width + pad * 2, height: size.height + pad)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
        }

        // Focus/crop chrome draws LAST so it sits on top (matching the old canvas
        // order). The exterior focus DIM stays in the magnified canvas.
        // Pending crop (crop tool): dashed "ants" + viewfinder brackets + hint. No dim.
        // Suppressed while the CANVAS is doing a replacement crop draw-out (crop tool
        // + canvas interactionInProgress + overlay not itself dragging) to avoid a
        // transient double-display of the old and new crop boundaries.
        if let pending = state.pendingCrop, !(state.selectedTool == .crop && state.interactionInProgress && focusDrag == nil) {
            let r = proj.screen(fromImage: pending)
            drawCropMarquee(in: r)
            drawCropHandles(in: r)   // dots (vs the focus viewfinder's brackets)
            drawCropHint(near: r)
            startCropAnts()
        } else {
            stopCropAnts()
        }
        // Focus: corner brackets always drawn (full-image viewfinder when no focus
        // is set, so the user can drag inward to CREATE a focus). The full-rect
        // white outline was removed: with no focus set it ran along the image
        // edges, under the overlay scrollbars, showing as a thin white line. The
        // exterior DIM (canvas, gated on focusRect/focusWorkingRect) plus the
        // corner brackets convey the focus edge.
        let focusR = proj.screen(fromImage: state.focusWorkingRect ?? state.effectiveFocusRect)
        drawFocusBrackets(in: focusR)
    }

    /// Stroke the viewfinder anchors (corner Ls + edge ticks) that mark the
    /// focus/crop rectangle `v` (screen space): a white halo under a softened
    /// black mark so they read over any image content, deliberately distinct
    /// from an object's filled resize dots.
    private func drawFocusBrackets(in v: CGRect) {
        let path = NSBezierPath()
        for s in focusBracketSegments(in: v, arm: focusArm, tick: focusTick) {
            path.move(to: s.a); path.line(to: s.b)
        }
        path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = focusWidth + 1.5; path.stroke()
        NSColor(white: 0.4, alpha: 1).setStroke(); path.lineWidth = focusWidth; path.stroke()
    }

    /// Filled resize DOTS at the crop rectangle's 4 corners + 4 edge midpoints —
    /// the same style as an object's resize handles (white fill, dark hairline),
    /// so the crop reads as "resize this rectangle" and is visually distinct from
    /// the focus-area viewfinder BRACKETS. Positions match `focusHandleHit`'s dots
    /// so each is grabbable.
    private func drawCropHandles(in v: CGRect) {
        let centers = [
            CGPoint(x: v.minX, y: v.minY), CGPoint(x: v.maxX, y: v.minY),
            CGPoint(x: v.minX, y: v.maxY), CGPoint(x: v.maxX, y: v.maxY),
            CGPoint(x: v.midX, y: v.minY), CGPoint(x: v.midX, y: v.maxY),
            CGPoint(x: v.minX, y: v.midY), CGPoint(x: v.maxX, y: v.midY),
        ]
        let d = handleDot
        for c in centers {
            let dot = NSBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            NSColor.white.setFill(); dot.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke(); dot.lineWidth = 1; dot.stroke()
        }
    }

    /// Dashed marching-ants outline for a pending crop (screen space). No
    /// exterior dim — the image stays fully visible; the outline alone tells
    /// the user what commit will keep.
    private func drawCropMarquee(in rect: CGRect) {
        NSColor(red: 0x4A/255.0, green: 0x9E/255.0, blue: 0xFF/255.0, alpha: 1.0).setStroke()
        let p = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        p.lineWidth = 2
        let dashes: [CGFloat] = [6, 4]
        // Negative phase marches the dashes forward (→) along the path; the
        // phase is advanced ~60fps by the crop-ants timer while a crop is pending.
        p.setLineDash(dashes, count: dashes.count, phase: -cropDashPhase)
        p.stroke()
    }

    /// "Press ⏎ to crop · Esc to cancel" hint near the pending crop (screen
    /// space). Anchored above the marquee when there's room, else just inside.
    private func drawCropHint(near rect: CGRect) {
        let label = "Press ⏎ to crop · Esc to cancel" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        let above = rect.minY - size.height - 14
        let textOrigin: CGPoint
        if above >= 4 {
            textOrigin = CGPoint(x: rect.midX - size.width / 2, y: above)
        } else {
            textOrigin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY + 8)
        }
        let bg = CGRect(
            x: textOrigin.x - 8, y: textOrigin.y - 4,
            width: size.width + 16, height: size.height + 8
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
        label.draw(at: textOrigin, withAttributes: attrs)
    }

    /// The image-space bounds a pending crop is constrained to (mirrors the
    /// canvas `currentImageSize()`): the destructive crop, else the full image.
    private func cropBoundsSize() -> CGSize {
        state.croppedRect?.size ?? CGSize(width: state.sourceImage.width, height: state.sourceImage.height)
    }

    /// The corner of `rect` that stays fixed when applying an aspect-ratio
    /// constraint after dragging `handle`. Corners anchor diagonally opposite;
    /// edges anchor the corner recommended by the drag direction (.top/.left →
    /// bottomRight, .bottom/.right → topLeft).
    private func cropAspectAnchor(for handle: FocusHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:        return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight:       return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight:    return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomLeft:     return CGPoint(x: rect.maxX, y: rect.minY)
        case .top, .left:     return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom, .right: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    /// Translate `rect` by `delta`, then nudge it back so it stays inside
    /// `bounds` (used to drag the pending crop without leaving the image).
    private func movedRect(_ rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
        var r = rect.offsetBy(dx: delta.x, dy: delta.y)
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        return r
    }

    private func drawObjectChrome(_ annotation: Annotation, proj: ChromeProjection, emphasized: Bool) {
        let b = geometryBounds(annotation.geometry)
        let center = CGPoint(x: b.midX, y: b.midY)
        let rotateM = transformMatrix(for: annotation.transform.rotationOnly, center: center)

        // Resize handles: handlePositions already applies the full annotation
        // transform, so positions are in transformed image space. Project directly
        // to screen — do NOT re-apply the transform here.
        let screenHandles = handlePositions(of: annotation, rotateOffset: 0)
            .filter { $0.0 != .rotate }
            .map { ($0.0, proj.screen(fromImage: $0.1)) }

        // Emphasis bounding box (transformed AABB), constant 1.5pt stroke. Shown
        // for the primary of a multi-selection AND for a selected text box —
        // whose glyphs have no border of their own, so a bare set of corner dots
        // is hard to read as a box.
        let isSelectedTextBox: Bool = {
            if case .text = annotation.geometry {
                return state.selectedAnnotationIDs.contains(annotation.id)
            }
            return false
        }()
        if emphasized || isSelectedTextBox {
            let aabb = transformedAABB(bounds: b, transform: annotation.transform)
            // A text box's frame sits ON the box rect (inset 0) so the resize dots
            // — which are at the rect's corners/edges — land on the line. The
            // multi-select emphasis box keeps a 5px margin around the shape.
            let inset: CGFloat = (isSelectedTextBox && !emphasized) ? 0 : -5
            let box = proj.screen(fromImage: aabb).insetBy(dx: inset, dy: inset)
            let path = NSBezierPath(rect: box); path.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke(); path.stroke()
        }

        // Rotate lollipop: stem from projected top-center up to a dot at a
        // constant screen offset (single-selection only).
        if state.selectedAnnotationIDs.count <= 1 {
            let topCenter = proj.screen(fromImage: CGPoint(x: b.midX, y: b.minY).applying(rotateM))
            let dotCenter = screenRotatePosition(topCenterScreen: topCenter, offset: rotateOffset)
            let stem = NSBezierPath(); stem.move(to: topCenter); stem.line(to: dotCenter)
            stem.lineWidth = 1
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke(); stem.stroke()
            let r = rotateDot
            let dot = NSBezierPath(ovalIn: CGRect(x: dotCenter.x - r, y: dotCenter.y - r, width: r*2, height: r*2))
            NSColor.controlAccentColor.setFill(); dot.fill()
            NSColor.white.setStroke(); dot.lineWidth = 1.5; dot.stroke()
        }

        // Resize dots.
        let d = handleDot
        for (_, c) in screenHandles {
            let dot = NSBezierPath(ovalIn: CGRect(x: c.x - d/2, y: c.y - d/2, width: d, height: d))
            (emphasized ? NSColor.controlAccentColor : NSColor.white).setFill(); dot.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke(); dot.lineWidth = 1; dot.stroke()
        }
    }
}
