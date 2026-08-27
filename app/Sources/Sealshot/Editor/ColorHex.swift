import AppKit

/// `"#RRGGBB"` for an opaque sRGB rendering of `color` (alpha ignored).
func hexString(from color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    let r = Int((c.redComponent   * 255).rounded())
    let g = Int((c.greenComponent * 255).rounded())
    let b = Int((c.blueComponent  * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
}

/// Parse `#RGB` / `#RRGGBB` (leading `#` optional) into an opaque sRGB color.
/// Returns nil for anything else.
func color(fromHex hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 {
        s = s.map { "\($0)\($0)" }.joined()   // expand RGB → RRGGBB
    }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    let r = CGFloat((value >> 16) & 0xFF) / 255
    let g = CGFloat((value >> 8) & 0xFF) / 255
    let b = CGFloat(value & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
