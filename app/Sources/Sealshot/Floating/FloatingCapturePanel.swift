import AppKit

/// The floating capture window itself. Deliberately a STANDALONE panel, never a
/// child window of the editor: a child is not composited on a display its
/// parent does not occupy (the bug that made the welcome-tour card vanish when
/// dragged to a second monitor), and a child cannot outlive its parent — but
/// this panel must survive the editor being closed, since surviving it is the
/// entire point.
final class FloatingCapturePanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 70),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        // Load-bearing: clicking the panel must NOT activate Sealshot.
        // `FullscreenCapturer` and `RegionCapturer` record the frontmost
        // application as the capture's source, so a panel that took focus would
        // make every capture it started claim Sealshot as its own source.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Dragging is handled manually so the RELEASE can snap to a corner.
        isMovableByWindowBackground = false
    }

    /// Never key. The consequence the controller must honor: the fade-at-rest
    /// effect has to be driven by mouse HOVER, because a focus-driven fade on a
    /// window that never takes focus would leave it permanently dim.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The grab bar across the top of the panel. The whole background still drags,
/// but nothing said so — a floating window with no visible handle reads as
/// fixed in place, so people don't try to move it. A centred bar is the same
/// shape macOS uses on sheets and widgets, so it needs no explaining.
final class FloatingCaptureGripView: NSView {

    static let barSize = NSSize(width: 30, height: 3)

    override var isFlipped: Bool { false }

    /// Decoration over the draggable background: it must not eat the
    /// mouse-down, or the one part that looks draggable would be the one part
    /// that isn't.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: bounds.midX - Self.barSize.width / 2,
                         y: bounds.midY - Self.barSize.height / 2,
                         width: Self.barSize.width, height: Self.barSize.height)
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bar,
                     xRadius: Self.barSize.height / 2,
                     yRadius: Self.barSize.height / 2).fill()
    }
}

/// The panel's content view: chrome, hover tracking, and the drag.
///
/// The drag works in SCREEN coordinates. An earlier version used an
/// `NSPanGestureRecognizer` and `translation(in: nil)`, which reports movement
/// in the WINDOW's coordinate space — so every frame moved the window, which
/// moved the space the next translation was measured in, and the panel jittered
/// and drifted away from the pointer. Anchoring to `NSEvent.mouseLocation`
/// removes the feedback loop entirely: the grab offset is fixed at mouse-down
/// and the window simply follows the pointer.
final class FloatingCaptureContentView: NSVisualEffectView {

    var onDragEnded: (() -> Void)?
    /// A press that never travelled — mouse up within 3pt of mouse down.
    /// The docked-line state restores the panel from this.
    var onClick: (() -> Void)?
    /// Fired continuously while dragging, so the controller can preview where
    /// the panel would snap if released now.
    var onDragMoved: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    /// Pointer position relative to the window's origin, frozen at mouse-down.
    private var grabOffset: NSPoint?
    private var pressOrigin: NSPoint?
    private var dragTravelled = false

    /// True between mouse-down and mouse-up on the panel. Auto-dock consults
    /// it: moving the window under the pointer makes the tracking area fire
    /// `mouseExited`, which would otherwise tuck the panel away mid-drag and
    /// leave the user unable to move it at all.
    var isDraggingPanel: Bool { grabOffset != nil }
    private var hoverTracking: NSTrackingArea?

    /// Fades in over the vibrancy when the pointer arrives. Raising the
    /// window's alpha alone still left the desktop showing THROUGH the
    /// material, so the panel you were about to click was the hardest thing on
    /// screen to read. Under the controls, so nothing else has to move.
    private let backdrop: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.alphaValue = 0
        return view
    }()

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard backdrop.superview == nil else { return }
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop, positioned: .below, relativeTo: nil)
        refreshBackdropColor()
    }

    /// Follow the appearance the material is actually rendering in, so going
    /// solid is the same panel with the translucency removed rather than a
    /// different-coloured one.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackdropColor()
    }

    private func refreshBackdropColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color: NSColor = isDark
            ? NSColor(calibratedWhite: 0.14, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
        backdrop.layer?.backgroundColor = color.cgColor
    }

    var backdropAlphaForTesting: CGFloat { backdrop.alphaValue }
    var backdropForTesting: NSView { backdrop }

    /// Opaque on hover, translucent at rest.
    func setSolidBackground(_ solid: Bool, animated: Bool = true) {
        guard animated else {
            backdrop.alphaValue = solid ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            backdrop.animator().alphaValue = solid ? 1 : 0
        }
    }

    override func mouseDown(with event: NSEvent) { beginDrag(pointer: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { drag(pointer: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { endDrag() }

    /// Freeze where in the panel the pointer grabbed it. Everything after this
    /// is arithmetic against that fixed offset, never against the window's
    /// current position — which is what makes the drag stable.
    private func beginDrag(pointer: NSPoint) {
        guard let window else { return }
        grabOffset = NSPoint(x: pointer.x - window.frame.minX,
                             y: pointer.y - window.frame.minY)
        pressOrigin = pointer
        dragTravelled = false
    }

    private func drag(pointer: NSPoint) {
        guard let window, let grabOffset else { return }
        if let origin = pressOrigin,
           hypot(pointer.x - origin.x, pointer.y - origin.y) >= 3 {
            dragTravelled = true
        }
        window.setFrameOrigin(NSPoint(x: pointer.x - grabOffset.x,
                                      y: pointer.y - grabOffset.y))
        onDragMoved?()
    }

    private func endDrag() {
        guard grabOffset != nil else { return }
        grabOffset = nil
        pressOrigin = nil
        // A press that never travelled is a CLICK, not a drag — the docked
        // line restores from it; a real drag settles/snaps as always.
        if dragTravelled {
            onDragEnded?()
        } else {
            onClick?()
        }
        dragTravelled = false
    }

    // Test hooks: the pointer position is the only input the drag has, so
    // feeding it directly exercises the real arithmetic without a mouse.
    func beginDragForTesting(pointer: NSPoint) { beginDrag(pointer: pointer) }
    func dragForTesting(pointer: NSPoint) { drag(pointer: pointer) }
    func endDragForTesting() { endDrag() }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    /// Rebuilt on every resize: the panel changes size when the user switches
    /// between compact/standard/strip, and a stale tracking rect would leave it
    /// stuck faded (or stuck bright) over part of its own bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    /// A hairline top highlight and a full border, so the panel reads as a
    /// physical object floating over the desktop rather than a flat grey patch.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(roundedRect: inset, xRadius: 11.5, yRadius: 11.5)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        border.lineWidth = 1
        border.stroke()
    }
}

/// A 16 pt chrome glyph — pin and close.
///
/// Deliberately NOT `ActiveToolPillView`: that is a fixed 28 pt pill sized for
/// the capture controls. Two of them across the top would make the panel a
/// quarter taller and would give controls you touch once a session the same
/// visual weight as the capture button.
final class FloatingChromeButton: HoverTooltipView {

    static let side: CGFloat = 16

    private let imageView = NSImageView()
    private let onClick: () -> Void

    init(symbolName: String, tooltip: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        // The panel never activates Sealshot; without this the tooltip is dead.
        tracksWhileAppInactive = true
        tooltipText = tooltip
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setSymbol(symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setSymbol(_ name: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    func setTooltip(_ text: String) {
        tooltipText = text
        setAccessibilityLabel(text)
    }

    /// Swallow the press so it never reaches the content view underneath, whose
    /// `mouseDown` starts a window drag.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick()
    }

    /// Test hook, mirroring `ActiveToolPillView.performClick`.
    func performClick() { onClick() }
}
