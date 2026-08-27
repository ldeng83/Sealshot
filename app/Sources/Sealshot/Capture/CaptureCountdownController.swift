import AppKit
import KeyboardShortcuts

/// The on-screen countdown shown before a delayed capture. A click-through,
/// non-activating panel (so the user can rearrange windows / switch apps during
/// the count) centered on EVERY display, drawing a depleting ring + the
/// remaining seconds, pulsing on the final second. Esc cancels (global Carbon
/// hotkey via the shared `.pickerCancel` binding — no accessibility permission).
@MainActor
final class CaptureCountdownController {

    private var panels: [NSPanel] = []
    private var rings: [CountdownRingView] = []
    private var timer: Timer?
    private var endDate: Date?
    private var total: Double = 0
    private var onComplete: (() -> Void)?
    private var onCancel: (() -> Void)?

    var isRunning: Bool { !panels.isEmpty }

    /// Begin a countdown of `seconds`. Re-entry while one is running is ignored.
    /// One centered ring is shown on every connected display.
    func start(seconds: Int, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        guard panels.isEmpty else { return }
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.total = Double(seconds)

        let size: CGFloat = 200
        for screen in NSScreen.screens {
            let ring = CountdownRingView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            let panel = Self.makePanel(size: size, ring: ring)
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2))
            panel.orderFrontRegardless()
            panels.append(panel)
            rings.append(ring)
        }

        KeyboardShortcuts.setShortcut(.init(.escape, modifiers: []), for: .pickerCancel)

        let end = Date().addingTimeInterval(total)
        endDate = end
        rings.forEach { $0.update(remaining: total, total: total) }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// A click-through, non-activating, always-on-top panel hosting one ring.
    private static func makePanel(size: CGFloat, ring: CountdownRingView) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true                       // click-through
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = ring
        return panel
    }

    /// Called from the global Esc hotkey while the countdown is up.
    func cancelFromGlobalEsc() {
        guard !panels.isEmpty else { return }
        let cb = onCancel
        teardown()
        cb?()
    }

    private func tick() {
        guard let end = endDate else { return }
        let remaining = end.timeIntervalSinceNow
        if remaining <= 0 {
            let cb = onComplete
            teardown()
            cb?()
        } else {
            rings.forEach { $0.update(remaining: remaining, total: total) }
        }
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        KeyboardShortcuts.setShortcut(nil, for: .pickerCancel)
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll(); rings.removeAll()
        endDate = nil; onComplete = nil; onCancel = nil
    }
}

/// Draws the countdown: a translucent disc, a depleting ring, the remaining
/// whole seconds, and an "Esc to cancel" caption. The number swells (and the
/// ring warms) during the final second.
final class CountdownRingView: NSView {

    private var remaining: Double = 0
    private var total: Double = 1

    override var isFlipped: Bool { false }

    func update(remaining: Double, total: Double) {
        self.remaining = max(0, remaining)
        self.total = max(0.0001, total)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 64
        let lineWidth: CGFloat = 8
        let isFinal = remaining <= 1.0

        // Translucent backing disc.
        let discR = radius + 18
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - discR, y: center.y - discR, width: discR * 2, height: discR * 2)).fill()

        // Track ring.
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.18).setStroke()
        track.stroke()

        // Remaining-fraction arc, depleting clockwise from the top.
        let frac = CGFloat(remaining / total)
        if frac > 0 {
            let prog = NSBezierPath()
            prog.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
            prog.lineWidth = lineWidth
            prog.lineCapStyle = .round
            (isFinal ? NSColor.systemOrange : NSColor.white).setStroke()
            prog.stroke()
        }

        // Remaining whole seconds, swelling during the final second.
        let n = max(1, Int(ceil(remaining)))
        let pulse = isFinal ? (1 + 0.18 * sin((1 - remaining) * .pi)) : 1
        let fontSize = 64 * CGFloat(pulse)
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: isFinal ? NSColor.systemOrange : NSColor.white,
        ]
        let num = "\(n)" as NSString
        let ns = num.size(withAttributes: numAttrs)
        num.draw(at: NSPoint(x: center.x - ns.width / 2, y: center.y - ns.height / 2), withAttributes: numAttrs)

        // Caption.
        let cap = "Esc to cancel" as NSString
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let cs = cap.size(withAttributes: capAttrs)
        cap.draw(at: NSPoint(x: center.x - cs.width / 2, y: center.y - 52), withAttributes: capAttrs)
    }
}
