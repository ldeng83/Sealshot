import XCTest
import AppKit
@testable import Sealshot

final class TextRunTests: XCTestCase {
    private func run(_ t: String, size: CGFloat = 18, bold: Bool = false,
                     color: SerializableColor = SerializableColor(r: 0, g: 0, b: 0, a: 1)) -> TextRun {
        TextRun(text: t, color: color, fontSize: size, isBold: bold)
    }

    func test_textRun_codecRoundTrip() throws {
        let runs = [run("Hello ", color: SerializableColor(r: 1, g: 0, b: 0, a: 1)),
                    run("world", size: 24, bold: true)]
        let data = try JSONEncoder().encode(runs)
        XCTAssertEqual(try JSONDecoder().decode([TextRun].self, from: data), runs)
    }

    func test_attributedString_carriesPerRunAttributes() {
        let runs = [run("A", size: 10), run("B", size: 30, bold: true)]
        let s = attributedString(for: runs, opacity: 1.0)
        XCTAssertEqual(s.string, "AB")
        let f0 = s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let f1 = s.attribute(.font, at: 1, effectiveRange: nil) as! NSFont
        XCTAssertEqual(f0.pointSize, 10, accuracy: 0.01)
        XCTAssertEqual(f1.pointSize, 30, accuracy: 0.01)
        XCTAssertTrue(f1.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_attributedString_appliesOpacityAndScale() {
        let runs = [run("X", size: 20, color: SerializableColor(r: 0, g: 0, b: 0, a: 1))]
        let s = attributedString(for: runs, opacity: 0.5, scale: 2)
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(font.pointSize, 40, accuracy: 0.01)
        let color = (s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor).usingColorSpace(.sRGB)!
        XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 0.02)
    }

    func test_runsFromAttributed_collapsesEqualSpans() {
        let r = [run("foo", color: SerializableColor(r: 1, g: 0, b: 0, a: 1)),
                 run("bar", size: 24)]
        let rebuilt = runs(from: attributedString(for: r, opacity: 1.0),
                           defaultColor: SerializableColor(r: 0, g: 0, b: 0, a: 1))
        XCTAssertEqual(rebuilt.count, 2)
        XCTAssertEqual(rebuilt[0].text, "foo")
        XCTAssertEqual(rebuilt[1].text, "bar")
        XCTAssertEqual(rebuilt[1].fontSize, 24, accuracy: 0.01)
    }

    func test_textBoxHeight_runs_narrowerWrapsTaller() {
        let r = [run("The quick brown fox jumps over the lazy dog", size: 18)]
        XCTAssertGreaterThan(textBoxHeight(runs: r, width: 80), textBoxHeight(runs: r, width: 400))
    }

    func test_textBoxHeight_runs_emptyIsOneLine() {
        XCTAssertGreaterThan(textBoxHeight(runs: [], width: 200), 0)
    }

    func test_runsFromAttributed_usesDefaultColorWhenMissing() {
        let s = NSAttributedString(string: "x", attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let fallback = SerializableColor(r: 0, g: 1, b: 0, a: 1)
        let rebuilt = runs(from: s, defaultColor: fallback)
        XCTAssertEqual(rebuilt.count, 1)
        XCTAssertEqual(rebuilt[0].color, fallback)
    }

    func test_attributed_runs_roundTripStable() {
        let original = [run("alpha ", color: SerializableColor(r: 1, g: 0, b: 0, a: 1)),
                        run("beta", size: 28, bold: true, color: SerializableColor(r: 0, g: 0, b: 1, a: 1))]
        let rebuilt = runs(from: attributedString(for: original, opacity: 1.0),
                           defaultColor: SerializableColor(r: 0, g: 0, b: 0, a: 1))
        XCTAssertEqual(rebuilt, original)
    }
}
