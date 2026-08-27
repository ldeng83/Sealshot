import XCTest
@testable import Sealshot

/// The Text tool's typographic defaults (family/size/bold/weight/italic/
/// underline/strike/highlight/outline/align/vertical/line-spacing) persist
/// across launches. Color and opacity are NOT here — those are per-tool
/// creation defaults covered by the tool color/opacity stores.
@MainActor
final class TextTypographyDefaultsTests: XCTestCase {

    private let key = "textTypographyDefaults.v1"

    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: key) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: key); super.tearDown() }

    private func state() -> EditorState {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return EditorState(sourceImage: ctx.makeImage()!, sourceURL: nil)
    }

    func testStoreRoundTrip() {
        var d = TextTypographyDefaults.fallback
        d.fontSize = 40
        d.weight = .bold
        d.underline = true
        d.outlineColor = SerializableColor(r: 0, g: 1, b: 0, a: 1)
        d.alignment = .center
        d.lineSpacing = 12
        TextTypographyDefaultsStore.current = d
        XCTAssertEqual(TextTypographyDefaultsStore.current, d)
    }

    func testUnsetFallsBackToDefaults() {
        // Nothing persisted → the fallback (18pt, left/top, no emphasis).
        let d = TextTypographyDefaultsStore.current
        XCTAssertEqual(d.fontSize, 18)
        XCTAssertEqual(d.alignment, .left)
        XCTAssertEqual(d.verticalAlignment, .top)
        XCTAssertFalse(d.isItalic)
    }

    func testTypographyPersistsAcrossStates() {
        let s1 = state()
        s1.textFontSize = 42
        s1.textIsItalic = true
        s1.textStrikethrough = true
        s1.textAlignment = .center
        s1.textVerticalAlignment = .middle
        s1.textLineSpacing = 9
        s1.textOutlineColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        // A fresh state (proxy for relaunch) seeds from the persisted store.
        let s2 = state()
        XCTAssertEqual(s2.textFontSize, 42)
        XCTAssertTrue(s2.textIsItalic)
        XCTAssertTrue(s2.textStrikethrough)
        XCTAssertEqual(s2.textAlignment, .center)
        XCTAssertEqual(s2.textVerticalAlignment, .middle)
        XCTAssertEqual(s2.textLineSpacing, 9)
        XCTAssertEqual(s2.textOutlineColor.map { SerializableColor($0) },
                       SerializableColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)))
    }

    func testLoadingDoesNotClobberStoreWithDefaults() {
        let s1 = state()
        s1.textFontSize = 33
        _ = state()   // its init loads (guarded) — must not overwrite the store with fallback
        XCTAssertEqual(TextTypographyDefaultsStore.current.fontSize, 33,
                       "a fresh state's guarded load must not re-persist fallback over saved values")
    }

    /// Editing a SELECTED text object via the object panel (updateTextRuns /
    /// updateTextBoxStyle) must adopt the FULL styling as creation defaults, so a
    /// new box inherits it — not just color/size/bold.
    func testObjectPanelEditAdoptsFullTypographyAsDefaults() {
        let s = state()
        let run = TextRun(text: "hi", color: SerializableColor(.black), fontSize: 20, isBold: false)
        let ann = Annotation(geometry: .text(rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                                             runs: [run]), style: Style(strokeColor: SerializableColor(.black), strokeWidth: 0))
        s.annotations.append(ann)
        let id = ann.id

        // Box-level edit (like the Paragraph controls).
        s.updateTextBoxStyle(id: id) { $0.textAlignment = .center; $0.textVerticalAlignment = .middle; $0.lineSpacing = 7 }
        XCTAssertEqual(s.textAlignment, .center)
        XCTAssertEqual(s.textVerticalAlignment, .middle)
        XCTAssertEqual(s.textLineSpacing, 7)

        // Per-run edit (like Weight / Emphasis / Outline).
        s.updateTextRuns(id: id) { runs in
            for i in runs.indices {
                runs[i].weight = .semibold; runs[i].isItalic = true
                runs[i].underline = true; runs[i].strikethrough = true
            }
        }
        XCTAssertEqual(s.textWeight, .semibold)
        XCTAssertTrue(s.textIsItalic)
        XCTAssertTrue(s.textUnderline)
        XCTAssertTrue(s.textStrikethrough)

        // And it persists (a fresh state seeds from the store).
        let s2 = state()
        XCTAssertEqual(s2.textAlignment, .center)
        XCTAssertEqual(s2.textWeight, .semibold)
        XCTAssertTrue(s2.textIsItalic)
    }
}
