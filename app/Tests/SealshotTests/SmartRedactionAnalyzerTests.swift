import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class SmartRedactionAnalyzerTests: XCTestCase {

    // MARK: - Pure layout → detections mapping

    /// One line "mail a@b.io" with even char boxes spanning x 0…1 at y 0.4.
    private func makeLayout() -> RecognizedTextLayout {
        let text = "mail a@b.io"
        let count = text.count
        let lineBox = CGRect(x: 0, y: 0.4, width: 1.0, height: 0.1)
        let charBoxes = (0..<count).map {
            CGRect(x: CGFloat($0) / CGFloat(count), y: 0.4,
                   width: 1.0 / CGFloat(count), height: 0.1)
        }
        return RecognizedTextLayout(lines: [RecognizedLine(text: text, box: lineBox,
                                                           charBoxes: charBoxes)])
    }

    func testDetections_mapsMatchIntoTileOffsetImageSpace() {
        // Tile is 1000×500 px starting at y=2000 in the full image.
        let tile = CGRect(x: 0, y: 2000, width: 1000, height: 500)
        let detections = SmartRedactionAnalyzer.detections(in: makeLayout(), tile: tile)

        XCTAssertEqual(detections.count, 1)
        let d = detections[0]
        XCTAssertEqual(d.category, .email)
        XCTAssertEqual(d.snippet, "a@b.io")
        XCTAssertEqual(d.rects.count, 1)
        let rect = d.rects[0]
        // "a@b.io" is chars 5..<11 of an 11-char line over 1000 px wide tile,
        // so ~x 454…1000, plus padding, offset to the tile's y origin.
        XCTAssertEqual(rect.minX, 5.0 / 11.0 * 1000.0 - 4, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(rect.minY, 2000)
        XCTAssertLessThanOrEqual(rect.maxY, 2500)
        XCTAssertEqual(rect.height, 500 * 0.1 + 8, accuracy: 0.5)
    }

    func testDetections_emptyLayoutYieldsNothing() {
        let layout = RecognizedTextLayout(lines: [])
        XCTAssertEqual(SmartRedactionAnalyzer.detections(
            in: layout, tile: CGRect(x: 0, y: 0, width: 100, height: 100)), [])
    }

    // MARK: - End-to-end with Vision

    /// White image with `string` drawn large and centered, as a CGImage of
    /// EXACTLY `width`×`height` pixels. Drawn into an explicit 1× bitmap rep
    /// rather than `NSImage.lockFocus`, which adopts the screen backing scale
    /// and yields a 2× image on Retina — breaking the dimension-relative
    /// position assertions below.
    private func textImage(_ string: String, width: Int = 800, height: Int = 200) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 40),
            .foregroundColor: NSColor.black,
        ]
        let s = NSAttributedString(string: string, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2,
                           y: (CGFloat(height) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    func testAnalyze_findsEmailInRenderedImage() async throws {
        let image = textImage("Contact: jane@example.com")
        let detections = try await SmartRedactionAnalyzer().analyze(image).detections

        let emails = detections.filter { $0.category == .email }
        XCTAssertEqual(emails.count, 1, "got: \(detections)")
        let rect = emails[0].rects[0]
        // The email occupies the right side of the centered text band.
        XCTAssertTrue(rect.midX > CGFloat(image.width) / 2)
        XCTAssertTrue(rect.midY > 40 && rect.midY < 160)
    }

    func testAnalyze_tiledImageDedupsOverlapBand() async throws {
        // Force tiling on a 200-tall image: 150 px tiles overlapping by 120
        // ensure the text band is fully inside more than one tile.
        let image = textImage("Contact: jane@example.com")
        let analyzer = SmartRedactionAnalyzer(maxTileHeight: 150, tileOverlap: 120)
        let detections = try await analyzer.analyze(image).detections

        let emails = detections.filter { $0.category == .email }
        XCTAssertEqual(emails.count, 1, "overlap band must dedup, got: \(emails)")
    }
}
