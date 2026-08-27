import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class TextRecognizerTests: XCTestCase {

    /// White image with `string` drawn large and centered, as a CGImage.
    private func textImage(_ string: String, width: Int = 600, height: Int = 200) -> CGImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 72),
            .foregroundColor: NSColor.black,
        ]
        let s = NSAttributedString(string: string, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2,
                           y: (CGFloat(height) - size.height) / 2))
        img.unlockFocus()
        var rect = NSRect(x: 0, y: 0, width: width, height: height)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }

    func testRecognizesKnownText() async throws {
        let recognizer = TextRecognizer()
        let layout = try await recognizer.recognize(textImage("HELLO WORLD"))
        let joined = layout.lines.map(\.text).joined(separator: " ").uppercased()
        XCTAssertTrue(joined.contains("HELLO"), "got: \(joined)")
        XCTAssertTrue(joined.contains("WORLD"), "got: \(joined)")
    }

    func testRecognizedLinesCarryAQuad() async throws {
        let recognizer = TextRecognizer()
        let layout = try await recognizer.recognize(textImage("HELLO"))
        XCTAssertFalse(layout.lines.isEmpty)
        for line in layout.lines {
            let quad = try XCTUnwrap(line.quad, "every recognized line should carry a tilt quad")
            // Corners live in normalized [0,1] top-left space.
            for p in [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft] {
                XCTAssertGreaterThanOrEqual(p.x, -0.001)
                XCTAssertLessThanOrEqual(p.x, 1.001)
                XCTAssertGreaterThanOrEqual(p.y, -0.001)
                XCTAssertLessThanOrEqual(p.y, 1.001)
            }
            // The visual top edge sits above the bottom edge (top-left origin).
            XCTAssertLessThan(quad.topLeft.y, quad.bottomLeft.y)
        }
    }

    func testCharBoxesMatchCharacterCount() async throws {
        let recognizer = TextRecognizer()
        let layout = try await recognizer.recognize(textImage("HELLO"))
        for line in layout.lines {
            XCTAssertEqual(line.charBoxes.count, line.text.count)
            for b in line.charBoxes {
                XCTAssertGreaterThanOrEqual(b.minY, -0.001)
                XCTAssertLessThanOrEqual(b.maxY, 1.001)
            }
        }
    }

    /// Non-Latin scripts must OCR as themselves — before language
    /// auto-detection was enabled, Vision assumed en-US and read CJK text as
    /// Latin garbage/replacement symbols.
    func testRecognizesChineseText() async throws {
        let recognizer = TextRecognizer()
        let layout = try await recognizer.recognize(textImage("你好世界"))
        let joined = layout.lines.map(\.text).joined()
        XCTAssertTrue(joined.contains("你好"), "expected Chinese read, got: \(joined)")
    }

    // MARK: foldStrayFullwidth

    func testFoldStrayFullwidth_asciiLineMisreadAsCJK() {
        // Corpus-verified misread: Vision's language auto-detection read an
        // ASCII phone line as Japanese.
        XCTAssertEqual(foldStrayFullwidth("［555）210・3350"), "[555)210-3350")
        // Fullwidth digits and letters fold to ASCII too.
        XCTAssertEqual(foldStrayFullwidth("５５５－１２３４"), "555-1234")
    }

    func testFoldStrayFullwidth_realCJKTextUntouched() {
        let japanese = "電話番号・０３です"       // has kana/ideograph letters
        XCTAssertEqual(foldStrayFullwidth(japanese), japanese)
        let chinese = "帐号（测试）"
        XCTAssertEqual(foldStrayFullwidth(chinese), chinese)
    }

    func testFoldStrayFullwidth_plainASCIIFastPath() {
        XCTAssertEqual(foldStrayFullwidth("(555) 210-3350"), "(555) 210-3350")
        XCTAssertEqual(foldStrayFullwidth("héllo café"), "héllo café")
    }

    func testFoldStrayFullwidth_preservesScalarCount() {
        let folded = foldStrayFullwidth("［555）210・3350")
        XCTAssertEqual(folded.count, "［555）210・3350".count)
    }
}
