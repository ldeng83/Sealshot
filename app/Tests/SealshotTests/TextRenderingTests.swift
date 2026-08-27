import XCTest
import AppKit
@testable import Sealshot

final class TextRenderingTests: XCTestCase {

    private func style(fontSize: CGFloat, bold: Bool = false, opacity: Double = 1.0) -> Style {
        Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 0,
              opacity: opacity, fontSize: fontSize, isBold: bold)
    }

    private func run(_ text: String, fontSize: CGFloat = 18, bold: Bool = false) -> TextRun {
        TextRun(text: text, color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: fontSize, isBold: bold)
    }

    func test_textBoxHeight_narrowerWrapsTaller() {
        let runs = [run("The quick brown fox jumps over the lazy dog")]
        let wide = textBoxHeight(runs: runs, width: 400)
        let narrow = textBoxHeight(runs: runs, width: 80)
        XCTAssertGreaterThan(narrow, wide)
    }

    func test_textBoxHeight_emptyIsAtLeastOneLine() {
        XCTAssertGreaterThan(textBoxHeight(runs: [run("")], width: 200), 0)
    }
}
