import AppKit

/// Opaque sRGB color expressed in hue/saturation/brightness (each 0…1).
struct HSB: Equatable {
    var hue: CGFloat
    var saturation: CGFloat
    var brightness: CGFloat

    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        self.hue = h >= 1 ? 0 : h; self.saturation = s; self.brightness = b
    }

    var nsColor: NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB) ?? .black
    }
}

/// Square saturation (x) × brightness (y) field for the current hue. Dragging
/// reports the new (saturation, brightness) via `onChange`. y-up: brightness
/// increases upward.
final class SaturationBrightnessView: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var saturation: CGFloat = 1 { didSet { needsDisplay = true } }
    var brightness: CGFloat = 1 { didSet { needsDisplay = true } }
    var onChange: ((_ saturation: CGFloat, _ brightness: CGFloat) -> Void)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()
        // Base: white → full-hue across x (saturation).
        let fullHue = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
        NSGradient(starting: .white, ending: fullHue)?.draw(in: r, angle: 0)
        // Overlay: transparent → black up the y axis (brightness).
        NSGradient(starting: NSColor(white: 0, alpha: 0), ending: .black)?.draw(in: r, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        // Knob (unclipped).
        let kx = r.minX + saturation * r.width
        let ky = r.minY + brightness * r.height
        let knob = NSBezierPath(ovalIn: NSRect(x: kx - 6, y: ky - 6, width: 12, height: 12))
        NSColor.white.setStroke(); knob.lineWidth = 2; knob.stroke()
        NSColor.black.withAlphaComponent(0.5).setStroke(); knob.lineWidth = 1; knob.stroke()
    }

    override func mouseDown(with event: NSEvent) { handle(event) }
    override func mouseDragged(with event: NSEvent) { handle(event) }

    private func handle(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = min(max(p.x / bounds.width, 0), 1)
        let b = min(max(p.y / bounds.height, 0), 1)
        saturation = s; brightness = b
        onChange?(s, b)
    }
}

/// Horizontal hue spectrum (0…1). Dragging reports the new hue via `onChange`.
final class HueSliderView: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).addClip()
        let fractions = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map { CGFloat($0) }
        let colors = fractions.map { NSColor(hue: $0, saturation: 1, brightness: 1, alpha: 1) }
        NSGradient(colors: colors, atLocations: fractions, colorSpace: .sRGB)?.draw(in: r, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        // Knob (unclipped).
        let kx = r.minX + hue * r.width
        let knob = NSBezierPath(ovalIn: NSRect(x: kx - r.height / 2, y: r.minY, width: r.height, height: r.height))
        NSColor.white.setStroke(); knob.lineWidth = 2; knob.stroke()
        NSColor.black.withAlphaComponent(0.5).setStroke(); knob.lineWidth = 1; knob.stroke()
    }

    override func mouseDown(with event: NSEvent) { handle(event) }
    override func mouseDragged(with event: NSEvent) { handle(event) }

    private func handle(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = min(max(p.x / bounds.width, 0), 1)
        hue = h
        onChange?(h)
    }
}
