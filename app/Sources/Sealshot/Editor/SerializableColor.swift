import AppKit

/// RGBA value type that round-trips an `NSColor` through `Codable` (which
/// `NSColor` itself does not adopt). Components are in sRGB color space,
/// 0–1, doubles for cross-platform JSON friendliness.
struct SerializableColor: Equatable, Codable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        self.r = Double(srgb.redComponent)
        self.g = Double(srgb.greenComponent)
        self.b = Double(srgb.blueComponent)
        self.a = Double(srgb.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

/// Normalize a color to opaque sRGB (alpha forced to 1). Colors are stored
/// opaque because shape/box opacity is a separate control. Returns the original
/// color if it can't be converted to sRGB.
func opaqueSRGB(_ color: NSColor) -> NSColor {
    guard let srgb = color.usingColorSpace(.sRGB) else { return color }
    return srgb.withAlphaComponent(1.0)
}
