import AppKit
import ScreenCaptureKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "capture")

/// The unified-capture overlay view (one per screen panel).
///
/// Hover state (default): the frozen screen is slightly dimmed (capture mode
/// is visibly on) and the element/window under the cursor is undimmed +
/// outlined. A drag past `UnifiedGesture.dragThreshold` switches to area
/// mode: stronger dim, selection rect punched out. Mouse-up captures the
/// window (click) or the area (drag); a click over empty desktop is a no-op.
///
/// The controller pushes the candidate window list via `setCandidates` and
/// routes cursor-move events to `handleMouseMoved` (a borderless panel can't
/// rely on `mouseMoved(with:)`).
final class UnifiedSelectionView: NSView, NSTextFieldDelegate {
    /// Fires with the window to capture (click on a highlighted window).
    var onWindow: ((SCWindow) -> Void)?
    /// Fires with the selected area in global AppKit coordinates.
    var onRegion: ((CGRect) -> Void)?
    /// Fires on Esc / right-click.
    var onCancel: (() -> Void)?
    /// Fires the moment a drag turns into an area selection, so the controller
    /// can clear stale highlights on the other screens' views.
    var onAreaDragStarted: (() -> Void)?

    /// Hint lines for the crosshair badge; the delayed-capture variant
    /// prepends a "screen frozen" line (set by the controller).
    var hintLines: [String] = CrosshairRender.Hints.unified

    /// This display's frozen image, feeding the loupe.
    var loupeImage: CGImage? {
        didSet {
            crosshairLayers.setFrozenImage(loupeImage)
            needsDisplay = true
        }
    }

    /// Hairlines + loupe live in CALayers, not `draw(_:)`. They span the whole
    /// screen, and NSView collapses dirty rects to their bounding box, so
    /// drawing them meant damaging the entire surface on every cursor move
    /// (measured: 1 rect, 100% coverage, ~25fps). Moving layers rasterizes
    /// nothing. The badge is still drawn — it is a small box near the cursor,
    /// so invalidating it is cheap.
    private let crosshairLayers = CrosshairLayers()
    /// Badge region from the last draw, so a move can invalidate the old
    /// position as well as the new one.
    private var lastBadgeFrame: CGRect = .zero

    private var candidates: [SCWindow] = []
    private var highlighted: SCWindow?
    /// Detected boundary rects (view-local) for this display's frozen image.
    private var boundaryRects: [CGRect] = []
    /// Latest accessibility-tree probe (rects already view-local) — the
    /// precision path; image-based boundaries fill in where AX has nothing.
    /// Refreshed asynchronously per hover bucket.
    private var axMode = AXElementProbe.ProbeResult.Mode.none
    private var axRects: [CGRect] = []
    private var axProbeBucket = CGPoint(x: -1, y: -1)
    private var axProbeTask: Task<Void, Never>?
    /// While the AX probe for the current position is in flight, the
    /// provisional (image/window) answer is NOT shown — the highlight
    /// commits once, settled, instead of visibly "thinking" through
    /// intermediate guesses. A stalled probe falls back to the provisional.
    private var axProbeInFlight = false
    private var axProbeGeneration = 0
    private var provisionalFallbackTask: Task<Void, Never>?
    /// The highlight GLIDES between targets instead of jumping: switches
    /// commit immediately (clicks always capture the real target), but the
    /// drawn rect follows with an exponential approach (see
    /// `highlightFollowTimeConstant`). The first highlight (nothing → a
    /// target) snaps.
    /// Time constant of the highlight's exponential approach: the rect closes
    /// ~99% of the remaining distance in this long. Replaces the old
    /// fixed-duration ease so retargeting mid-flight stays continuous.
    ///
    /// Deliberately matched to the 0.15s the old fixed-duration ease took. The
    /// original SPEED was right — only its continuity was wrong — and a faster
    /// value (0.09s was tried) makes hovering across windows read as flashy,
    /// because each switch now completes instead of being smoothed by the slow
    /// tail of an ease that rarely finished.
    private static let highlightFollowTimeConstant: TimeInterval = 0.15
    private var displayedHighlightRect: CGRect?
    private var highlightAnimTarget: CGRect = .zero
    private var highlightAnimLastTick: CFTimeInterval = 0
    private var highlightAnimTimer: Timer?
    /// Floor between visible target switches: changes arriving faster than
    /// this are deferred and the freshest answer commits when the dwell
    /// elapses — rapid-fire switching reads as flicker even when animated.
    private static let minSwitchInterval: TimeInterval = 0.2
    private var lastSwitchTime: CFTimeInterval = 0
    private var deferredSwitchTask: Task<Void, Never>?
    /// How long a new hover target must persist before it is shown, so windows
    /// merely crossed on the way to the intended one never highlight. Adds to
    /// the time-to-highlight, which is the deliberate trade: arriving at the
    /// target you MEANT also waits this long.
    private static let hoverDwellInterval: TimeInterval = 0.25
    private var pendingCandidate: BoundaryCandidates.Candidate?
    private var pendingFrontWindowID: UInt32?
    private var pendingSince: CFTimeInterval = 0
    private var dwellTask: Task<Void, Never>?
    /// Candidates under the cursor, smallest first; `hoverLevel` indexes into
    /// it — the scroll wheel walks outward (button → card → panel → window).
    private var hoverStack: [BoundaryCandidates.Candidate] = []
    private var hoverLevel = 0
    /// Accumulated scroll delta since the last hover-level step (see
    /// `scrollWheel`), so one physical gesture moves one level.
    private var scrollAccumulator: CGFloat = 0
    private var dragStart: CGPoint?
    private var pressPoint: CGPoint?
    private var currentRect: CGRect = .zero
    private var isSelecting = false

    // Adjustable area selection (⌘-drag): after the rough drag, the box stays
    // on screen with handles + a ✓/✕ bar until the user confirms (Return / ✓).
    private var adjustIntent = false           // ⌘ was held at mousedown
    private var isAdjusting = false
    private var activeHandle: SelectionAdjust.Handle?
    private var dragLastPoint: CGPoint?        // for interior-move deltas
    private let handleSize: CGFloat = 14
    private let minSelectionSize: CGFloat = 20
    private let seedSize = CGSize(width: 240, height: 150)
    // Editable size pill (adjust mode only): two pixel fields W × H.
    private var widthField: NSTextField?
    private var heightField: NSTextField?
    private var sizePill: NSView?

    /// Latest cursor location (view-local), for the cursor + the hover tip.
    private var mousePoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    // AppKit has no public diagonal resize cursors, so build them once (App
    // Store-safe — no private API). Edges use the public left/right + up/down.
    private static let resizeNWSE = makeDiagonalCursor(nesw: false)
    private static let resizeNESW = makeDiagonalCursor(nesw: true)

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        crosshairLayers.setContentsScale(window?.backingScaleFactor ?? 2)
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    /// Capture is often triggered by a global hotkey while another app is
    /// active — without this, AppKit withholds the first click as an
    /// activation click and the user's first drag selects nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setCandidates(_ windows: [SCWindow]) {
        candidates = windows
        if !isSelecting && !isAdjusting { recomputeHighlight() }
    }

    /// Driven by the controller's `.mouseMoved` monitors.
    func handleMouseMoved() {
        syncMousePointToCursor()
        if !isSelecting && !isAdjusting { recomputeHighlight() }
    }

    /// The crosshair follows `mousePoint`, which this view's own tracking
    /// area maintains — but AppKit can SKIP the mouseExited when the cursor
    /// jumps screens quickly, stranding a crosshair on the display the
    /// cursor left. The controller fans every mouse move (local + global)
    /// to ALL views; deriving the point from the actual cursor location
    /// heals a stale crosshair on the next move anywhere.
    private func syncMousePointToCursor() {
        guard let screen = window?.screen else { return }
        let global = NSEvent.mouseLocation
        if screen.frame.contains(global) {
            // Panel fills the screen, so view-local == screen-local.
            let moved = CGPoint(x: global.x - screen.frame.minX,
                                y: global.y - screen.frame.minY)
            if moved != mousePoint {
                let previous = mousePoint
                mousePoint = moved
                // Invalidate on cursor movement. Without this the crosshair and
                // loupe only repainted when the HIGHLIGHT changed — a path that
                // is rate-limited (`minSwitchInterval`), glide-animated, and
                // skipped entirely while an AX probe is in flight. Measured:
                // moves arrived at 90-246/s and cost 0.03ms each, while the view
                // redrew just 22-27 times a second, so the crosshair was
                // effectively riding the highlight animation timer instead of
                // the cursor.
                //
                // Only the chrome regions are invalidated, not the whole view.
                // Our drawing is cheap (0.6ms/frame) but this display runs a
                // SCALED Retina mode — 1680x1050 points on a 2880x1800 panel,
                // so the window server renders 3360x2100 and rescales it — and
                // damaging the full surface every move caps the overlay near
                // 30fps on integrated graphics. The backdrop behind us is a
                // frozen frame that never changes, so repainting it is pure
                // waste.
                syncCrosshairLayers()
                // Only the badge is still drawn, so only the badge is damaged —
                // its old box and its new one, both beside the cursor.
                let previousBadge = lastBadgeFrame
                if !previousBadge.isEmpty { setNeedsDisplay(previousBadge.insetBy(dx: -2, dy: -2)) }
                if let next = badgeFrame(for: moved) { setNeedsDisplay(next.insetBy(dx: -2, dy: -2)) }
                _ = previous
            }
        } else if mousePoint != nil {
            mousePoint = nil
            if !isSelecting && !isAdjusting { needsDisplay = true }
        }
    }

    /// Total area AppKit is actually repainting this pass. `getRectsBeingDrawn`
    /// exposes the individual damaged rects; `dirtyRect` alone is only their
    /// bounding box, which for a crosshair is the whole screen.
    private func damagedArea(fallback dirtyRect: NSRect) -> Double {
        var rects: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&rects, count: &count)
        guard let rects, count > 0 else {
            return Double(dirtyRect.width * dirtyRect.height)
        }
        var total = 0.0
        for i in 0..<count { total += Double(rects[i].width * rects[i].height) }
        return total
    }

    /// How many separate rects AppKit is repainting this pass.
    private func damagedRectCount() -> Int {
        var rects: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&rects, count: &count)
        return count
    }

    /// Mark only the highlight regions for redraw. The dim fill is uniform, so
    /// outside the old and new highlight rects nothing changes: the old region
    /// goes back to dim, the new one gets punched clear and stroked. Padded for
    /// the glow stroke, which straddles the rect edge.
    private func invalidateHighlight(from old: CGRect?, to new: CGRect?) {
        if let old { setNeedsDisplay(old.insetBy(dx: -8, dy: -8)) }
        if let new { setNeedsDisplay(new.insetBy(dx: -8, dy: -8)) }
    }

    /// Push the current cursor/mode into the crosshair layers. Called from the
    /// move handler rather than `draw`, because cursor movement no longer
    /// invalidates the view at all.
    private func syncCrosshairLayers() {
        crosshairLayers.update(point: mousePoint, in: bounds,
                               visible: !isAdjusting)
    }

    /// The badge's rect for `point` under the current mode, or nil when no
    /// badge would be drawn.
    private func badgeFrame(for point: CGPoint) -> CGRect? {
        guard !isAdjusting, bounds.contains(point) else { return nil }
        let scale = window?.backingScaleFactor ?? 1.0
        let primary: String
        let hints: [String]
        if isSelecting {
            let ppi = window?.screen.map(DisplayMetrics.ppi(of:)) ?? 0
            primary = CrosshairRender.dimensionsText(rect: currentRect, scale: scale, ppi: ppi)
            hints = []
        } else {
            primary = CrosshairRender.coordsText(
                point: point, viewHeight: bounds.height, scale: scale)
            hints = hintLines
        }
        return CrosshairRender.badgeFrame(
            at: point, in: bounds, primary: primary, hints: hints,
            loupeFrame: loupeImage == nil ? nil : CrosshairRender.loupeFrame(at: point, in: bounds))
    }

    /// Detected boundary rects (view-local) for this display's frozen image.
    /// Pushed asynchronously after the freeze; refreshes the hover if idle.
    func setBoundaryRects(_ rects: [CGRect]) {
        boundaryRects = rects
        if !isSelecting && !isAdjusting { recomputeHighlight() }
    }

    /// Pixel-split page-body rects per browser window (view-local), the
    /// permission-free fallback used when the AX probe yields nothing.
    private var browserContentRects: [UInt32: CGRect] = [:]

    func setBrowserContentRects(_ rects: [UInt32: CGRect]) {
        browserContentRects = rects
        if !isSelecting && !isAdjusting { recomputeHighlight() }
    }

    /// Clear the hover outline (used on the non-dragging screens once a drag
    /// begins elsewhere).
    func clearHighlight() {
        highlightAnimTimer?.invalidate()
        highlightAnimTimer = nil
        displayedHighlightRect = nil
        deferredSwitchTask?.cancel()
        deferredSwitchTask = nil
        // Also drop the crosshair: during a drag only drag events flow (no
        // mouse-moved fan-out), so a crosshair stranded here by a skipped
        // mouseExited couldn't heal until the drag ended.
        if mousePoint != nil {
            mousePoint = nil
            needsDisplay = true
        }
        if highlighted != nil || !hoverStack.isEmpty {
            highlighted = nil
            hoverStack = []
            hoverLevel = 0
            needsDisplay = true
        }
    }

    /// Leave adjustable-area mode without capturing. Called on the OTHER
    /// displays' views when a new ⌘-selection starts somewhere, so only one
    /// adjustable box exists at a time across all screens.
    func exitAdjust() {
        guard isAdjusting || adjustIntent || !currentRect.isEmpty else { return }
        if widthField?.currentEditor() != nil || heightField?.currentEditor() != nil {
            window?.makeFirstResponder(self)   // end any in-progress field edit
        }
        isAdjusting = false
        adjustIntent = false
        isSelecting = false
        activeHandle = nil
        currentRect = .zero
        sizePill?.isHidden = true
        needsDisplay = true
    }

    // MARK: - Drawing

    /// Drives the highlight glide timer (see `animateHighlight`).
    private var glideActive = false

    override func draw(_ dirtyRect: NSRect) {
        if isSelecting || isAdjusting {
            drawAreaSelection()
            if isAdjusting { drawAdjustChrome() }
            if isSelecting, let p = mousePoint, bounds.contains(p) {
                drawCrosshair(at: p, dragging: true)
            }
        } else {
            drawWindowHighlight()
            if let p = mousePoint, bounds.contains(p) {
                drawCrosshair(at: p, dragging: false)
            }
        }
    }

    /// Shared crosshair: hairlines + badge + loupe. The loupe stays visible
    /// over window/boundary highlights too — on a real desktop nearly every
    /// pixel has a candidate under it, so suppressing there meant the loupe
    /// effectively never appeared.
    private func drawCrosshair(at point: CGPoint, dragging: Bool) {
        let scale = window?.backingScaleFactor ?? 1.0
        let primary: String
        let hints: [String]
        if dragging {
            let ppi = window?.screen.map(DisplayMetrics.ppi(of:)) ?? 0
            primary = CrosshairRender.dimensionsText(rect: currentRect, scale: scale, ppi: ppi)
            hints = []
        } else {
            primary = CrosshairRender.coordsText(
                point: point, viewHeight: bounds.height, scale: scale)
            hints = hintLines
        }
        // Hairlines and loupe are layers now (see `crosshairLayers`); only the
        // badge is still rasterized here.
        let loupe = loupeImage == nil ? nil : CrosshairRender.loupeFrame(at: point, in: bounds)
        CrosshairRender.drawBadgeOnly(at: point, in: bounds, primary: primary,
                                      hints: hints, loupeFrame: loupe)
        lastBadgeFrame = CrosshairRender.badgeFrame(
            at: point, in: bounds, primary: primary, hints: hints, loupeFrame: loupe)
    }

    /// Resize handles + the ✓/✕ control bar, drawn over the selection rect
    /// while in adjust mode.
    private func drawAdjustChrome() {
        guard !currentRect.isEmpty else { return }
        let rects = SelectionAdjust.handleRects(for: currentRect, size: handleSize)
        for (_, r) in rects {
            let dot = NSBezierPath(ovalIn: r)
            NSColor.white.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
        let bars = SelectionAdjust.controlBarRects(for: currentRect, in: bounds)
        drawControlButton(bars.capture, symbol: "checkmark", background: .systemGreen)
        drawControlButton(bars.cancel, symbol: "xmark", background: .systemRed)
        layoutSizePill()
    }

    private func drawControlButton(_ rect: CGRect, symbol: String, background: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        background.setFill()
        path.fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        // Render the template glyph in white, centered.
        let white = NSImage(size: glyph.size, flipped: false) { r in
            glyph.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = white.size
        white.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                              width: s.width, height: s.height))
    }

    private func drawWindowHighlight() {
        // Hover: a slight dim over the frozen screen signals capture mode;
        // the current hover candidate — a detected boundary or the window
        // under the cursor — is punched back to full brightness with the
        // glow border (stroke shared with the ⌘⇧W picker so modes match).
        // `displayedHighlightRect` glides between targets; clicks always
        // act on the real `currentCandidate`.
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()
        guard currentCandidate != nil, let rect = displayedHighlightRect else { return }
        NSGraphicsContext.current?.compositingOperation = .clear
        rect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        WindowHighlightStyle.strokeHighlight(rect)
    }

    /// The hover candidate the scroll level currently points at.
    private var currentCandidate: BoundaryCandidates.Candidate? {
        hoverStack.isEmpty ? nil : hoverStack[min(hoverLevel, hoverStack.count - 1)]
    }

    private func drawAreaSelection() {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        guard !currentRect.isEmpty else { return }

        NSGraphicsContext.current?.compositingOperation = .clear
        currentRect.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.white.setStroke()
        let path = NSBezierPath(rect: currentRect)
        path.lineWidth = 2
        path.stroke()
        // Dimensions render in the crosshair badge (drawCrosshair).
    }

    /// SCWindow frame (global, top-left origin) → this panel's view-local rect
    /// (bottom-left origin, isFlipped=false). Off-screen for windows on a
    /// different display, which simply draws nothing visible. Delegates to
    /// `FrozenFrameCrop` so the highlight and the frozen-frame crop use the
    /// same mapping.
    private func viewRect(forWindowFrame global: CGRect, on screen: NSScreen) -> CGRect {
        FrozenFrameCrop.windowViewLocalRect(
            windowFrame: global, screenFrame: screen.frame,
            primaryMaxY: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)
    }

    // MARK: - Size pill

    private func makeSizeField() -> NSTextField {
        let f = NSTextField(string: "")
        // Light-filled with dark text: reads cleanly against the opaque dark
        // pill, which in turn separates it from bright captures behind.
        f.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        f.alignment = .center
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = true
        f.backgroundColor = NSColor(white: 0.95, alpha: 1.0)
        f.textColor = .black
        f.focusRingType = .none
        f.wantsLayer = true
        f.layer?.cornerRadius = 5
        f.layer?.masksToBounds = true
        f.translatesAutoresizingMaskIntoConstraints = true
        f.delegate = self
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 1
        fmt.allowsFloats = false
        f.formatter = fmt
        return f
    }

    private func ensureSizePill() {
        guard sizePill == nil else { return }
        let w = makeSizeField(); let h = makeSizeField()
        let times = NSTextField(labelWithString: "×")
        times.font = .systemFont(ofSize: 13)
        times.textColor = NSColor(white: 1, alpha: 0.7)
        let unit = NSTextField(labelWithString: "px")
        unit.font = .systemFont(ofSize: 12)
        unit.textColor = NSColor(white: 1, alpha: 0.7)
        let stack = NSStackView(views: [w, times, h, unit])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.wantsLayer = true
        // Opaque dark bar + soft drop shadow + accent hairline border so the
        // readout stays legible over bright/busy captures. masksToBounds stays
        // false so the shadow shows; cornerRadius still rounds the fill+border.
        stack.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.77).cgColor
        stack.layer?.cornerRadius = 8
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        stack.layer?.masksToBounds = false
        stack.layer?.shadowColor = NSColor.black.cgColor
        stack.layer?.shadowOpacity = 0.55
        stack.layer?.shadowRadius = 5
        stack.layer?.shadowOffset = CGSize(width: 0, height: -2)
        NSLayoutConstraint.activate([
            w.widthAnchor.constraint(equalToConstant: 56),
            h.widthAnchor.constraint(equalToConstant: 56),
        ])
        w.nextKeyView = h
        h.nextKeyView = w
        addSubview(stack)
        widthField = w; heightField = h; sizePill = stack
    }

    /// Position the size pill centered above the selection, flipping below if
    /// there's no room. Hidden unless adjusting.
    private func layoutSizePill() {
        guard isAdjusting, !currentRect.isEmpty else { sizePill?.isHidden = true; return }
        ensureSizePill()
        guard let pill = sizePill else { return }
        pill.isHidden = false
        syncFieldsToRect()
        pill.layoutSubtreeIfNeeded()
        let size = pill.fittingSize
        let gap: CGFloat = 8
        var y = currentRect.maxY + gap                       // above the box
        if y + size.height > bounds.maxY { y = currentRect.minY - gap - size.height } // flip below
        let x = min(max(currentRect.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        pill.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func syncFieldsToRect() {
        let scale = window?.backingScaleFactor ?? 1.0
        let px = CoordinateMath.pixelSize(points: currentRect.size, scale: scale)
        // Don't stomp the field the user is editing.
        if widthField?.currentEditor() == nil { widthField?.stringValue = "\(px.width)" }
        if heightField?.currentEditor() == nil { heightField?.stringValue = "\(px.height)" }
    }

    private func applySizeFromFields() {
        let scale = window?.backingScaleFactor ?? 1.0
        let curPx = CoordinateMath.pixelSize(points: currentRect.size, scale: scale)
        let w = Int(widthField?.stringValue ?? "") ?? curPx.width
        let h = Int(heightField?.stringValue ?? "") ?? curPx.height
        currentRect = SelectionAdjust.resized(currentRect, toPixelSize: (w, h),
                                              scale: scale, in: bounds, minSize: minSelectionSize)
        syncFieldsToRect()   // reflect any clamping into the non-editing field
        needsDisplay = true
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        // Highlight the active field in the accent color.
        guard let f = obj.object as? NSTextField else { return }
        f.layer?.borderColor = NSColor.controlAccentColor.cgColor
        f.layer?.borderWidth = 2
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        widthField?.layer?.borderWidth = 0
        heightField?.layer?.borderWidth = 0
        applySizeFromFields()
        let movement = obj.userInfo?["NSTextMovement"] as? Int
        if movement == NSTextMovement.return.rawValue {
            // Return → resign focus so the next Return confirms the capture.
            window?.makeFirstResponder(self)
        }
        // Tab / backtab → let AppKit advance to nextKeyView (W↔H); don't resign.
    }

    // MARK: - Mouse / keyboard

    override func mouseDown(with event: NSEvent) {
        defer { syncCrosshairLayers() }
        let point = convert(event.locationInWindow, from: nil)
        mousePoint = point
        if isAdjusting {
            beginAdjustDrag(at: point)
            return
        }
        dragStart = point
        pressPoint = point
        currentRect = .zero
        isSelecting = false
        // ⌘ at mousedown means "adjustable area selection" — start drawing
        // immediately (even over a window) and never capture on release.
        adjustIntent = event.modifierFlags.contains(.command)
        if adjustIntent {
            highlighted = nil
            isSelecting = true
            onAreaDragStarted?()
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        defer { syncCrosshairLayers() }
        let current = convert(event.locationInWindow, from: nil)
        mousePoint = current
        if isAdjusting {
            guard let handle = activeHandle else { return }
            if handle == .interior {
                NSCursor.closedHand.set()
                if let last = dragLastPoint {
                    let delta = CGSize(width: current.x - last.x, height: current.y - last.y)
                    currentRect = SelectionAdjust.move(currentRect, by: delta, in: bounds)
                }
                dragLastPoint = current
            } else {
                currentRect = SelectionAdjust.resize(currentRect, handle: handle,
                                                     to: current, in: bounds, minSize: minSelectionSize)
            }
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        if !isSelecting, UnifiedGesture.isAreaDrag(from: start, to: current) {
            isSelecting = true
            highlighted = nil           // hide the outline once we're selecting
            onAreaDragStarted?()
        }
        guard isSelecting else { return }
        let raw = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        currentRect = CoordinateMath.clampToBounds(raw, bounds: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { syncCrosshairLayers() }
        if isAdjusting {
            // End the resize/move sub-drag; stay in adjust mode.
            activeHandle = nil
            dragLastPoint = nil
            return
        }
        guard dragStart != nil else { return }
        dragStart = nil

        // ⌘-drag: enter adjust mode instead of capturing. Seed a default box if
        // the drag was too small to be usable (e.g. ran out of trackpad space).
        if adjustIntent {
            adjustIntent = false
            isSelecting = false
            if currentRect.width < minSelectionSize || currentRect.height < minSelectionSize {
                let anchor = pressPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
                // cmd+CLICK recalls the last-captured size (cmd+DRAG keeps its
                // dragged size and never reaches this branch). Fall back to the
                // default box when nothing is remembered yet.
                let scale = window?.backingScaleFactor ?? 1.0
                let size = SelectionSizePreference.current()
                    .map { CoordinateMath.pointSize(pixels: $0, scale: scale) } ?? seedSize
                currentRect = SelectionAdjust.seededRect(around: anchor, default: size, in: bounds)
            }
            isAdjusting = true
            // Ensure this panel is key + first responder so Return reaches us
            // (matters when the drag happened on a non-primary display).
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            needsDisplay = true
            return
        }

        switch UnifiedGesture.outcome(enteredAreaMode: isSelecting,
                                      hasHighlightedWindow: currentCandidate != nil) {
        case .region:
            isSelecting = false
            if currentRect.isEmpty { needsDisplay = true; return }
            let windowRect = convert(currentRect, to: nil)
            let globalRect = window?.convertToScreen(windowRect) ?? .zero
            onRegion?(globalRect)
        case .window:
            // Click captures the hover candidate: a window via the window
            // path, a detected boundary as a region crop of its rect.
            switch currentCandidate?.kind {
            case .window:
                if let win = highlighted { onWindow?(win) }
            case .boundary:
                if let rect = currentCandidate?.rect {
                    let windowRect = convert(rect, to: nil)
                    let globalRect = window?.convertToScreen(windowRect) ?? .zero
                    onRegion?(globalRect)
                }
            case nil:
                break
            }
        case .none:
            // Clicked empty desktop without dragging — stay in the overlay.
            isSelecting = false
            needsDisplay = true
        }
    }

    /// In adjust mode, a mousedown either hits a control button (✓/✕) or starts
    /// a handle resize / interior move.
    private func beginAdjustDrag(at point: CGPoint) {
        // Clicks on the size pill are handled by the text fields themselves.
        if let pill = sizePill, !pill.isHidden, pill.frame.contains(point) { return }
        let bars = SelectionAdjust.controlBarRects(for: currentRect, in: bounds)
        if bars.capture.contains(point) { confirmAdjust(); return }
        if bars.cancel.contains(point) { sizePill?.isHidden = true; onCancel?(); return }
        activeHandle = SelectionAdjust.hitTest(point, in: currentRect, handleSize: handleSize)
        dragLastPoint = point
    }

    /// Commit the adjusted box as the captured region.
    private func confirmAdjust() {
        guard !currentRect.isEmpty else { sizePill?.isHidden = true; onCancel?(); return }
        isAdjusting = false
        sizePill?.isHidden = true
        // Remember this size (pixels) so the next cmd+click recalls it.
        let scale = window?.backingScaleFactor ?? 1.0
        let px = CoordinateMath.pixelSize(points: currentRect.size, scale: scale)
        SelectionSizePreference.set(width: px.width, height: px.height)
        let windowRect = convert(currentRect, to: nil)
        let globalRect = window?.convertToScreen(windowRect) ?? .zero
        onRegion?(globalRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        sizePill?.isHidden = true
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {          // Esc
            sizePill?.isHidden = true
            onCancel?()
        } else if event.keyCode == 36, isAdjusting {   // Return — confirm
            confirmAdjust()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Cursor + hover tip (tracking area, reliable on a borderless panel)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Hide the system cursor before the first move — the view draws its
        // own crosshair.
        if window != nil { CrosshairRender.transparentCursor.set() }
        installCrosshairLayers()
    }

    /// Attach the crosshair layer tree. Done here, not in `init`: a view's
    /// `layer` is not available until it is backed, so adding the sublayer at
    /// construction silently does nothing and the crosshair never appears.
    private func installCrosshairLayers() {
        guard window != nil else { return }
        wantsLayer = true
        guard let layer, crosshairLayers.root.superlayer !== layer else { return }
        layer.addSublayer(crosshairLayers.root)
        crosshairLayers.setContentsScale(window?.backingScaleFactor ?? 2)
        crosshairLayers.setFrozenImage(loupeImage)
        // Seed the cursor position. The overlay appears under a cursor that has
        // not moved yet, and the crosshair is hidden while `mousePoint` is nil —
        // so without this it stays invisible until the user nudges the mouse.
        syncMousePointToCursor()
        syncCrosshairLayers()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
        // `handleMouseMoved` owns both the position and the invalidation: it
        // derives `mousePoint` from the real cursor location (which also heals
        // a stale crosshair when AppKit drops a mouseExited) and marks only the
        // crosshair chrome dirty. Setting `mousePoint` here first defeated that
        // — the change was already applied, so the targeted invalidation saw no
        // movement — and the blanket `needsDisplay` that followed damaged the
        // whole screen every move regardless.
        handleMouseMoved()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard mousePoint != nil else { return }
        mousePoint = nil
        if !isSelecting && !isAdjusting { needsDisplay = true }
    }

    /// Transparent cursor while choosing (the drawn crosshair replaces it);
    /// in adjust mode, a resize cursor over a handle, an open hand over the
    /// interior, an arrow over the ✓/✕ buttons.
    private func updateCursor(at point: CGPoint) {
        guard isAdjusting else { CrosshairRender.transparentCursor.set(); return }
        let bars = SelectionAdjust.controlBarRects(for: currentRect, in: bounds)
        if bars.capture.contains(point) || bars.cancel.contains(point) {
            NSCursor.arrow.set(); return
        }
        cursorForHandle(SelectionAdjust.hitTest(point, in: currentRect, handleSize: handleSize)).set()
    }

    private func cursorForHandle(_ handle: SelectionAdjust.Handle?) -> NSCursor {
        switch handle {
        case .left, .right:               return .resizeLeftRight
        case .top, .bottom:               return .resizeUpDown
        case .topLeft, .bottomRight:      return Self.resizeNWSE
        case .topRight, .bottomLeft:      return Self.resizeNESW
        case .interior:                   return .openHand
        case .none:                       return .arrow
        }
    }

    /// A double-headed diagonal arrow cursor (`nesw` = "/" orientation, else "\").
    private static func makeDiagonalCursor(nesw: Bool) -> NSCursor {
        let dim: CGFloat = 24
        let image = NSImage(size: NSSize(width: dim, height: dim), flipped: false) { _ in
            let a: NSPoint, b: NSPoint
            if nesw { a = NSPoint(x: 5, y: 5);  b = NSPoint(x: 19, y: 19) }
            else    { a = NSPoint(x: 5, y: 19); b = NSPoint(x: 19, y: 5) }
            let path = NSBezierPath()
            path.move(to: a); path.line(to: b)
            let head: CGFloat = 6
            func barbs(at tip: NSPoint, from other: NSPoint) {
                let dx = tip.x - other.x, dy = tip.y - other.y
                let len = max(hypot(dx, dy), 0.001)
                let ux = dx / len, uy = dy / len
                for angle in [0.6, -0.6] as [CGFloat] {
                    let ca = cos(angle), sa = sin(angle)
                    let bx = -(ux * ca - uy * sa), by = -(ux * sa + uy * ca)
                    path.move(to: tip)
                    path.line(to: NSPoint(x: tip.x + bx * head, y: tip.y + by * head))
                }
            }
            barbs(at: a, from: b)
            barbs(at: b, from: a)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke(); path.lineWidth = 3.5; path.stroke()   // halo
            NSColor.black.setStroke(); path.lineWidth = 1.5; path.stroke()   // core
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: dim / 2, y: dim / 2))
    }

    private func recomputeHighlight() {
        guard let panelScreen = window?.screen else { return }
        let global = NSEvent.mouseLocation
        let local = CGPoint(x: global.x - panelScreen.frame.minX,
                            y: global.y - panelScreen.frame.minY)
        // One window candidate (the frontmost hit, by z-order) + every
        // detected boundary containing the cursor, smallest first.
        let frontHit = frontmostWindow(atGlobalAppKit: global, in: candidates)
        let windowRects: [(UInt32, CGRect)] = frontHit.map {
            [($0.windowID, viewRect(forWindowFrame: $0.frame, on: panelScreen))]
        } ?? []
        kickAXProbe(globalAppKit: global, frontHit: frontHit, screen: panelScreen)
        let stack = BoundaryCandidates(
            boundaryRects: hoverBoundaryRects(frontWindowID: frontHit?.windowID),
            windowRects: windowRects).stack(at: local)
        if axProbeInFlight {
            // The settled answer is a probe-completion away — hold the
            // provisional guess instead of flashing it. If the probe stalls,
            // commit the provisional after a beat.
            if provisionalFallbackTask == nil {
                provisionalFallbackTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.provisionalFallbackTask = nil
                    if self.axProbeInFlight {
                        self.axProbeInFlight = false
                        self.recomputeHighlight()
                    }
                }
            }
            return
        }
        // Empty desktop: offer the WHOLE DISPLAY as the target instead of
        // highlighting nothing. Hovering bare desktop previously proposed no
        // candidate at all, so there was nothing to see and a click did
        // nothing (`UnifiedGesture.outcome` → `.none`). A full-screen
        // `.boundary` candidate reuses the existing click path, which crops a
        // boundary's rect as a region — here, the entire screen.
        applyHover(stack: stack.isEmpty ? [Self.fullScreenCandidate(in: bounds)] : stack,
                   frontHit: frontHit)
    }

    /// Re-evaluate the hover once the dwell has elapsed. Needed because the
    /// cursor may come to rest on the new target, in which case no further
    /// mouse events arrive to drive `recomputeHighlight`.
    private func scheduleDwellRecheck(after seconds: TimeInterval) {
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.dwellTask = nil
            if !self.isSelecting, !self.isAdjusting { self.recomputeHighlight() }
        }
    }

    /// The whole display as a hover candidate. `.boundary` rather than
    /// `.window` on purpose: there is no `SCWindow` behind it, and the boundary
    /// click path already captures a candidate's rect as a region.
    private static func fullScreenCandidate(in bounds: CGRect) -> BoundaryCandidates.Candidate {
        BoundaryCandidates.Candidate(kind: .boundary, rect: bounds)
    }

    private func applyHover(stack: [BoundaryCandidates.Candidate], frontHit: SCWindow?) {
        // Rate-limit visible target switches: if the last switch was under
        // `minSwitchInterval` ago, wait out the remainder and re-evaluate —
        // the freshest answer wins, intermediate ones are never shown. The
        // first highlight (nothing → a target) is exempt.
        let isSwitch = stack.first != hoverStack.first && !hoverStack.isEmpty
        let now = CACurrentMediaTime()
        if isSwitch, now - lastSwitchTime < Self.minSwitchInterval {
            if deferredSwitchTask == nil {
                let wait = Self.minSwitchInterval - (now - lastSwitchTime)
                deferredSwitchTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.deferredSwitchTask = nil
                    if !self.isSelecting, !self.isAdjusting { self.recomputeHighlight() }
                }
            }
            return
        }
        deferredSwitchTask?.cancel()
        deferredSwitchTask = nil

        // DWELL: a new target must persist for `hoverDwellInterval` before it
        // is shown. Crossing a window on the way somewhere else should not
        // light it up — previously the highlight began moving ~40-60ms after
        // entering any area (an AX probe plus one render frame), so every
        // window in the cursor's path flashed. The committed highlight stays
        // put until a candidate has been held long enough to look intentional.
        //
        // A re-check is scheduled because the cursor may STOP on the new
        // target: with no further mouse events, nothing would re-evaluate and
        // the highlight would never commit.
        let wantsSwitch = stack != hoverStack || frontHit?.windowID != highlighted?.windowID
        if wantsSwitch, !hoverStack.isEmpty {
            if stack.first != pendingCandidate || frontHit?.windowID != pendingFrontWindowID {
                pendingCandidate = stack.first
                pendingFrontWindowID = frontHit?.windowID
                pendingSince = now
                // Scheduled ONCE per new candidate. This used to run on every
                // move while dwelling — cancelling and recreating a Task per
                // mouse event (210 times in a 20s session). Hitches tracked the
                // MOVE RATE rather than the damage, which is the signature of
                // per-event churn rather than drawing cost.
                scheduleDwellRecheck(after: Self.hoverDwellInterval)
            }
            if now - pendingSince < Self.hoverDwellInterval {
                return
            }
        }
        dwellTask?.cancel()
        dwellTask = nil
        pendingCandidate = nil
        pendingFrontWindowID = nil

        if isSwitch || (stack.first != hoverStack.first) { hoverLevel = 0 }  // new target → innermost
        if stack != hoverStack || frontHit?.windowID != highlighted?.windowID {
            if stack.first != hoverStack.first { lastSwitchTime = now }
            hoverStack = stack
            highlighted = frontHit
            let previousHighlight = displayedHighlightRect
            animateHighlight(to: currentCandidate?.rect)
            invalidateHighlight(from: previousHighlight, to: displayedHighlightRect)
        }
        hoverLevel = min(hoverLevel, max(0, hoverStack.count - 1))
    }

    /// Glide the drawn highlight toward `target` with a short ease-out.
    /// First appearance and disappearance snap — only target-to-target
    /// changes animate.
    /// Glide the highlight toward `target`.
    ///
    /// Retargeting does NOT restart the animation. The previous version reset
    /// `highlightAnimStart` and the clock on every call, so each scroll event
    /// began a fresh ease-out from wherever the rect happened to be — measured
    /// at 41 restarts across 42 scroll events, which is what made the box lurch
    /// and stall instead of growing smoothly. Now a running timer simply
    /// follows the newest target, so motion stays continuous however often the
    /// target changes.
    ///
    /// The curve is an exponential approach rather than a fixed-duration ease:
    /// it is frame-rate independent (uses real elapsed time) and has no
    /// "end" to restart from, which is precisely the property retargeting
    /// needs.
    private func animateHighlight(to target: CGRect?) {
        guard let target else {
            highlightAnimTimer?.invalidate()
            highlightAnimTimer = nil
            displayedHighlightRect = nil
            glideActive = false
            return
        }
        guard let from = displayedHighlightRect, from != target else {
            highlightAnimTimer?.invalidate()
            highlightAnimTimer = nil
            displayedHighlightRect = target
            glideActive = false
            return
        }
        highlightAnimTarget = target
        if highlightAnimTimer != nil { return }

        glideActive = true
        highlightAnimLastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let now = CACurrentMediaTime()
                let dt = max(0, now - self.highlightAnimLastTick)
                self.highlightAnimLastTick = now
                let goal = self.highlightAnimTarget
                let current = self.displayedHighlightRect ?? goal
                // Fraction of the remaining distance to close this tick. Derived
                // from elapsed time so a slow frame still advances correctly.
                let k = CGFloat(1 - pow(0.01, dt / Self.highlightFollowTimeConstant))
                let previousRect = self.displayedHighlightRect
                var next = Self.lerp(current, goal, min(1, max(0, k)))
                let settled = max(abs(next.minX - goal.minX), abs(next.minY - goal.minY),
                                  abs(next.maxX - goal.maxX), abs(next.maxY - goal.maxY)) < 0.5
                if settled { next = goal }
                self.displayedHighlightRect = next
                // Each tick only moves the highlight; damaging the whole screen
                // 60 times over the glide is what the crosshair fix was for.
                self.invalidateHighlight(from: previousRect, to: next)
                if settled {
                    timer.invalidate()
                    self.highlightAnimTimer = nil
                    self.glideActive = false
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        highlightAnimTimer = timer
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    /// The boundary-candidate set for the current hover, by probe mode:
    /// browsers offer exactly two targets (content area / whole window);
    /// elsewhere AX frames are authoritative where present, image detection
    /// fills the gaps, and everything respects the minimum candidate size.
    private func hoverBoundaryRects(frontWindowID: UInt32?) -> [CGRect] {
        let minSize = AXElementProbe.minElementSize
        let sizableImageRects = boundaryRects.filter {
            $0.width >= minSize.width && $0.height >= minSize.height
        }
        switch axMode {
        case .browserContent:
            return axRects                    // just the page content area
        case .browserChrome:
            return []                         // whole window only
        case .elements:
            // Image rects that approximate an AX frame are dropped — the AX
            // frame is exact and duplicates would clutter scroll-cycling.
            let imageRects = sizableImageRects.filter { img in
                !axRects.contains { ax in
                    abs(img.minX - ax.minX) < 8 && abs(img.minY - ax.minY) < 8
                        && abs(img.maxX - ax.maxX) < 8 && abs(img.maxY - ax.maxY) < 8
                }
            }
            return imageRects + axRects
        case .none:
            // AX gave nothing (no Accessibility grant, or no usable tree) —
            // the hovered browser window still gets its pixel-split page-body
            // candidate, permission-free (BrowserChromeSplit on the frozen
            // frame). Containment does the rest: cursor in the body → content
            // rect is the inner candidate; cursor in the chrome → window only.
            if let id = frontWindowID, let content = browserContentRects[id] {
                return sizableImageRects + [content]
            }
            return sizableImageRects
        }
    }

    /// Ask the hovered app's accessibility tree for the element stack under
    /// the cursor — off the main thread (AX is XPC to the target app and can
    /// stall), bucketed so small cursor jitters don't re-query, and merged
    /// into the hover stack when it lands.
    private func kickAXProbe(globalAppKit: CGPoint, frontHit: SCWindow?, screen: NSScreen) {
        guard let pid = frontHit?.owningApplication?.processID else {
            if !axRects.isEmpty || axMode != .none {
                axRects = []
                axMode = .none
            }
            return
        }
        let bundleID = frontHit?.owningApplication?.bundleIdentifier
        let bucket = CGPoint(x: (globalAppKit.x / 16).rounded(),
                             y: (globalAppKit.y / 16).rounded())
        guard bucket != axProbeBucket else { return }
        axProbeBucket = bucket
        // AX hit-testing wants global TOP-LEFT (CG) coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: globalAppKit.x, y: primaryHeight - globalAppKit.y)
        axProbeGeneration += 1
        let generation = axProbeGeneration
        axProbeInFlight = true
        provisionalFallbackTask?.cancel()
        provisionalFallbackTask = nil
        axProbeTask?.cancel()
        axProbeTask = Task { [weak self] in
            let probe = await Task.detached(priority: .userInitiated) {
                AXElementProbe.probe(at: cgPoint, pid: pid, bundleID: bundleID)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, generation == self.axProbeGeneration else { return }
                self.axProbeInFlight = false
                self.provisionalFallbackTask?.cancel()
                self.provisionalFallbackTask = nil
                let local = probe.rects.map { self.viewRect(forWindowFrame: $0, on: screen) }
                if local != self.axRects || probe.mode != self.axMode {
                    self.axRects = local
                    self.axMode = probe.mode
                }
                if !self.isSelecting, !self.isAdjusting { self.recomputeHighlight() }
            }
        }
    }

    /// Scroll while hovering walks the candidate stack outward/inward
    /// (button → card → panel → window).
    override func scrollWheel(with event: NSEvent) {
        guard !isSelecting, !isAdjusting, hoverStack.count > 1 else { return }
        // (a) Momentum: macOS keeps sending coasting events after the user has
        // stopped scrolling. Stepping the hover level on those walks the stack
        // on its own, well after the gesture ended.
        guard event.momentumPhase == [] else { return }

        // (b) One level per gesture-worth of scrolling, not one per EVENT. A
        // flick produced 42 events 4-5ms apart (measured), each stepping a
        // level — so the highlight raced through the stack. Deltas accumulate
        // to a threshold instead; a classic wheel notch reports ~1 "line" and
        // still steps once, while high-resolution and trackpad devices report
        // many small point deltas that now add up to a single step.
        scrollAccumulator += event.scrollingDeltaY
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
        guard abs(scrollAccumulator) >= step else { return }
        let goingUp = scrollAccumulator > 0
        scrollAccumulator = 0
        if goingUp {
            hoverLevel = min(hoverLevel + 1, hoverStack.count - 1)
        } else {
            hoverLevel = max(hoverLevel - 1, 0)
        }
        let previousHighlight = displayedHighlightRect
        animateHighlight(to: currentCandidate?.rect)
        invalidateHighlight(from: previousHighlight, to: displayedHighlightRect)
    }


}
