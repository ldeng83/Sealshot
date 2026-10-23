import XCTest
import AppKit
@testable import Sealshot

/// Vision reads a capital O next to digits as a zero ("O-1042" → "0-1042",
/// "OO7" → "007") whatever the language-correction setting; the glyph's own
/// shape is what tells them apart.
@MainActor
final class RoundGlyphDisambiguationTests: XCTestCase {

    /// White image with `string` drawn in `font`, at 2x like a Retina capture.
    private func textImage(_ string: String, font: NSFont) -> CGImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let s = NSAttributedString(string: string, attributes: attrs)
        let size = NSSize(width: s.size().width + 40, height: s.size().height + 30)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                   pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        s.draw(at: NSPoint(x: 20, y: 15))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private func read(_ string: String, _ font: NSFont) async throws -> String {
        let layout = try await TextRecognizer().recognize(textImage(string, font: font))
        return layout.lines.map(\.text).joined(separator: " ")
    }

    // MARK: End to end

    func testLetterOInCodesIsReadAsO_proportionalFont() async throws {
        let font = NSFont(name: "Helvetica", size: 22)!
        let a = try await read("SKU A0O-0O9", font)
        XCTAssertEqual(a, "SKU A0O-0O9")
        let b = try await read("OO7 Agent", font)
        XCTAssertEqual(b, "OO7 Agent")
    }

    func testLetterOInCodesIsReadAsO_monospacedFontWithMarkedZero() async throws {
        let font = NSFont(name: "Menlo", size: 22)!
        let a = try await read("Order ID: O-1042", font)
        XCTAssertEqual(a, "Order ID: O-1042")
        let b = try await read("KEY 0OX9-O0Z1", font)
        XCTAssertEqual(b, "KEY 0OX9-O0Z1")
    }

    /// Real zeros must stay zeros — a false O in a number is worse than the bug.
    func testRealZerosStayZeros() async throws {
        for font in [NSFont(name: "Helvetica", size: 22)!, NSFont(name: "Menlo", size: 22)!,
                     NSFont.systemFont(ofSize: 22), NSFont.boldSystemFont(ofSize: 22)] {
            let a = try await read("Version 10.0", font)
            XCTAssertEqual(a, "Version 10.0", font.fontName)
            let b = try await read("Room 101", font)
            XCTAssertEqual(b, "Room 101", font.fontName)
        }
    }

    // MARK: Decision rule

    private func g(_ read: Character, _ aspect: CGFloat, _ center: CGFloat,
                   height: CGFloat = 30) -> RoundGlyph {
        RoundGlyph(read: read, aspect: aspect, centerInk: center, inkHeight: height)
    }

    func testMarkedZeroInLine_hollowOnesAreLetters() {
        // Menlo: the slashed zero has centre ink; a hollow round glyph beside it is an O.
        XCTAssertEqual(RoundGlyph.resolve([g("0", 0.62, 0.46), g("0", 0.65, 0.0)]), ["0", "O"])
    }

    func testTwoWidthGroups_wideOnesAreLetters() {
        XCTAssertEqual(RoundGlyph.resolve([g("0", 0.69, 0), g("0", 0.94, 0), g("O", 0.69, 0)]),
                       ["0", "O", "0"])
    }

    func testSingleWideGlyph_isALetter() {
        XCTAssertEqual(RoundGlyph.resolve([g("0", 0.94, 0), g("0", 0.94, 0)]), ["O", "O"])
    }

    func testSingleNarrowHollowGlyph_keepsTheRead() {
        // SF Mono's O and a proportional 0 measure alike — no evidence, no change.
        XCTAssertEqual(RoundGlyph.resolve([g("0", 0.70, 0)]), ["0"])
        XCTAssertEqual(RoundGlyph.resolve([g("O", 0.70, 0)]), ["O"])
    }

    func testTinyGlyphs_keepTheRead() {
        // A few pixels tall, one pixel of antialiasing swings the aspect — no call.
        XCTAssertEqual(RoundGlyph.resolve([g("0", 0.9, 0, height: 6)]), ["0"])
    }
}
