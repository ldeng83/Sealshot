import AppKit

/// The floating recording dot. Collapsed: a red dot + elapsed time (amber pause
/// glyph when paused). Hover expands it to add Pause/Stop; a click pins it open.
/// Dragging the dot moves the panel. Flipped coordinates (top-left origin) so
/// text and glyphs lay out predictably.
@MainActor
final class RecordingHUDView: NSView {
    var state = RecordingHUDState() { didSet { if state != oldValue { needsDisplay = true } } }

    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onExpansionChange: (() -> Void)?   // controller resizes the panel to fit
    var onMoved: (() -> Void)?             // persist position after a drag

    /// The pill runs at ~32pt (up from the original 28pt design — too small to
    /// spot); every metric scales by this factor so proportions are unchanged.
    static let sizeScale: CGFloat = 32.0 / 28.0

    private let h: CGFloat = 28 * sizeScale
    private let pad: CGFloat = 11 * sizeScale
    private let gap: CGFloat = 9 * sizeScale
    private let icon: CGFloat = 11 * sizeScale
    private let btn: CGFloat = 15 * sizeScale
    private var didDrag = false

    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5 * sizeScale, weight: .semibold)
    /// Leftmost status label font ("Recording" / "Paused") — replaces the dot.
    static let statusFont = NSFont.systemFont(ofSize: 11.5 * sizeScale, weight: .semibold)

    // Entrance pulse: nil when idle; while set, `draw` scales the dot and adds
    // a fading glow ring. Stepped manually at 60fps (the view is draw()-based).
    private var pulseProgress: CGFloat?
    private var pulsesRemaining = 0
    private var pulseTimer: Timer?
    private static let pulseDuration: TimeInterval = 0.55

    override var isFlipped: Bool { true }

    // MARK: Layout

    /// Tighter gap between the status icon and its label (they read as a pair).
    private var iconGap: CGFloat { gap * 0.6 }

    /// Size the panel should be for the current (collapsed/expanded) state.
    var desiredSize: NSSize {
        var w = pad + icon + iconGap + statusWidth + gap + timeWidth
        if state.isExpanded { w += gap + btn + gap + btn }
        return NSSize(width: w + pad, height: h)
    }

    private var timeWidth: CGFloat {
        ceil((state.timeText as NSString).size(withAttributes: [.font: Self.timeFont]).width)
    }
    /// Leftmost status text + color: red "Recording", orange "Paused".
    private var statusText: String { state.isPaused ? "Paused" : "Recording" }
    private var statusColor: NSColor { state.isPaused ? .systemOrange : .systemRed }
    /// Reserve the WIDER of the two labels so the time/buttons never shift or
    /// clip when toggling between "Recording" and "Paused".
    private var statusWidth: CGFloat {
        ceil(["Recording", "Paused"]
            .map { ($0 as NSString).size(withAttributes: [.font: Self.statusFont]).width }
            .max() ?? 0)
    }
    private var iconRect: NSRect { NSRect(x: pad, y: (h - icon) / 2, width: icon, height: icon) }
    private var statusRect: NSRect { NSRect(x: pad + icon + iconGap, y: 0, width: statusWidth, height: h) }
    private var timeRect: NSRect { NSRect(x: statusRect.maxX + gap, y: 0, width: timeWidth, height: h) }
    private var pauseRect: NSRect { NSRect(x: timeRect.maxX + gap, y: (h - btn) / 2, width: btn, height: btn) }
    private var stopRect: NSRect { NSRect(x: pauseRect.maxX + gap, y: (h - btn) / 2, width: btn, height: btn) }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2)
        NSColor(white: 0.11, alpha: 0.93).setFill(); pill.fill()
        NSColor(white: 1, alpha: 0.13).setStroke(); pill.lineWidth = 1; pill.stroke()

        // Leftmost status icon: red dot (recording) / orange pause bars (paused).
        if state.isPaused {
            NSColor.systemOrange.setFill()
            let r = iconRect, bw = r.width * 0.34
            NSBezierPath(rect: NSRect(x: r.minX, y: r.minY, width: bw, height: r.height)).fill()
            NSBezierPath(rect: NSRect(x: r.maxX - bw, y: r.minY, width: bw, height: r.height)).fill()
        } else {
            if let p = pulseProgress {
                // Glow ring grows out from the dot and fades; capped just inside
                // the pill so it never clips flat against the panel edge.
                let center = NSPoint(x: iconRect.midX, y: iconRect.midY)
                let radius = min(icon / 2 + (h / 2 - icon / 2 - 1) * p, h / 2 - 1)
                NSColor.systemRed.withAlphaComponent(0.55 * (1 - p)).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
            NSColor.systemRed.setFill()
            let scale = 1 + 0.28 * sin(.pi * (pulseProgress ?? 0))
            let grown = (icon * scale - icon) / 2
            NSBezierPath(ovalIn: iconRect.insetBy(dx: -grown, dy: -grown)).fill()
        }

        // Status label beside the icon (red "Recording" / orange "Paused").
        let statusPara = NSMutableParagraphStyle(); statusPara.alignment = .left
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.statusFont, .foregroundColor: statusColor, .paragraphStyle: statusPara]
        let sH = (statusText as NSString).size(withAttributes: statusAttrs).height
        (statusText as NSString).draw(
            in: NSRect(x: statusRect.minX, y: (h - sH) / 2, width: statusRect.width, height: sH),
            withAttributes: statusAttrs)

        let para = NSMutableParagraphStyle(); para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.timeFont, .foregroundColor: NSColor.white, .paragraphStyle: para]
        let textH = (state.timeText as NSString).size(withAttributes: attrs).height
        (state.timeText as NSString).draw(
            in: NSRect(x: timeRect.minX, y: (h - textH) / 2, width: timeRect.width, height: textH),
            withAttributes: attrs)

        if state.isExpanded {
            if state.isPaused {
                // Resume = a filled circle (like the record button) but in the
                // same white-gray as the pause bars, not red — a play triangle
                // read as media playback and confused.
                NSColor(white: 0.92, alpha: 1).setFill()
                NSBezierPath(ovalIn: pauseRect.insetBy(dx: 1.5, dy: 1.5)).fill()
            } else {
                NSColor(white: 0.92, alpha: 1).setFill()
                drawPauseBars(in: pauseRect.insetBy(dx: 2, dy: 1)) // pause = two bars
            }
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: stopRect.insetBy(dx: 2.5, dy: 2.5), xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawPauseBars(in r: NSRect) {
        let bw = r.width * 0.34
        NSBezierPath(rect: NSRect(x: r.minX, y: r.minY, width: bw, height: r.height)).fill()
        NSBezierPath(rect: NSRect(x: r.maxX - bw, y: r.minY, width: bw, height: r.height)).fill()
    }

    // MARK: Entrance pulse

    /// Pulse the red dot `count` times (scale-up + fading glow ring) — the
    /// start-of-recording attention grab. Self-terminating; safe to call again.
    func beginEntrancePulse(count: Int) {
        pulseTimer?.invalidate()
        pulsesRemaining = count
        pulseProgress = 0
        let step = 1.0 / (Self.pulseDuration * 60)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, var p = self.pulseProgress else { timer.invalidate(); return }
                p += step
                if p >= 1 {
                    self.pulsesRemaining -= 1
                    if self.pulsesRemaining <= 0 {
                        timer.invalidate()
                        self.pulseTimer = nil
                        self.pulseProgress = nil
                    } else {
                        self.pulseProgress = 0
                    }
                } else {
                    self.pulseProgress = p
                }
                self.needsDisplay = true
            }
        }
        pulseTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ inside: Bool) {
        var s = state; s.setHovering(inside); state = s
        onExpansionChange?()
    }

    // MARK: Click / pin / drag

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if state.isExpanded {
            if pauseRect.insetBy(dx: -4, dy: -4).contains(p) { onPause?(); return }
            if stopRect.insetBy(dx: -4, dy: -4).contains(p) { onStop?(); return }
        }
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        var origin = window.frame.origin
        origin.x += event.deltaX
        origin.y -= event.deltaY
        window.setFrameOrigin(origin)
        didDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { onMoved?(); return }
        var s = state; s.togglePin(); state = s
        onExpansionChange?()
    }
}

/// The entrance chevron — a white "look here" glyph under the "Recording"
/// caption that bounces toward the pill a few times, then reports completion
/// so the controller can fade its panel out. Points down when the stack sits
/// above the pill; up when the HUD is parked near the top of the screen and
/// the stack flips below. Stepped manually at 60fps like the dot pulse.
@MainActor
final class RecordingChevronView: NSView {
    static let chevronSize = NSSize(width: 30, height: 18)
    static let travel: CGFloat = 9
    /// Panel is tall enough for the glyph plus its bounce travel.
    static var panelSize: NSSize {
        NSSize(width: chevronSize.width, height: chevronSize.height + travel)
    }

    private let pointsDown: Bool
    private var phase: CGFloat = 0            // 0..1 within one bounce
    private var timer: Timer?
    var onFinished: (() -> Void)?

    init(pointsDown: Bool) {
        self.pointsDown = pointsDown
        super.init(frame: NSRect(origin: .zero, size: Self.panelSize))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func beginBounce(count: Int, duration: TimeInterval = 0.55) {
        timer?.invalidate()
        var remaining = count
        phase = 0
        let step = 1.0 / (duration * 60)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.phase += step
                if self.phase >= 1 {
                    self.phase = 0
                    remaining -= 1
                    if remaining <= 0 {
                        timer.invalidate()
                        self.timer = nil
                        self.needsDisplay = true
                        self.onFinished?()
                        return
                    }
                }
                self.needsDisplay = true
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Flipped coords: +y is downward on screen. The glyph rests away from
        // the pill and bounces toward it (down when pointing down, up when up).
        let offset = Self.travel * sin(.pi * min(max(phase, 0), 1))
        let y = pointsDown ? offset : Self.travel - offset
        let r = NSRect(x: 0, y: y, width: Self.chevronSize.width, height: Self.chevronSize.height)

        let p = NSBezierPath()
        p.lineWidth = 4.5
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        let inset: CGFloat = 3
        if pointsDown {
            p.move(to: NSPoint(x: r.minX + inset, y: r.minY + inset))
            p.line(to: NSPoint(x: r.midX, y: r.maxY - inset))
            p.line(to: NSPoint(x: r.maxX - inset, y: r.minY + inset))
        } else {
            p.move(to: NSPoint(x: r.minX + inset, y: r.maxY - inset))
            p.line(to: NSPoint(x: r.midX, y: r.minY + inset))
            p.line(to: NSPoint(x: r.maxX - inset, y: r.maxY - inset))
        }
        NSColor.white.setStroke()
        p.stroke()
    }
}
