import XCTest
import AppKit
@testable import Sealshot

/// The text object panel applies color/font/bold uniformly across every run of
/// the selected text box (per-word styling stays in the inline editor).
final class TextObjectRestyleTests: XCTestCase {

    @MainActor
    private func makeState(runs: [TextRun]) -> (EditorState, UUID) {
        let size = CGSize(width: 20, height: 20)
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.white.set(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill(); img.unlockFocus()
        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let state = EditorState(sourceImage: cg, sourceURL: nil)
        let ann = Annotation(geometry: .text(rect: CGRect(x: 0, y: 0, width: 100, height: 30), runs: runs),
                             style: Style(strokeColor: SerializableColor(.black), strokeWidth: 0))
        state.annotations = [ann]
        state.selectOnly(ann.id)
        return (state, ann.id)
    }

    private func run(_ t: String, size: CGFloat, bold: Bool = false) -> TextRun {
        TextRun(text: t, color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: size, isBold: bold)
    }

    @MainActor
    func test_updateSelectedTextRuns_setsUniformFontSize() {
        let (state, id) = makeState(runs: [run("A", size: 12), run("B", size: 30, bold: true)])
        state.updateSelectedTextRuns { runs in for i in runs.indices { runs[i].fontSize = 22 } }
        guard case let .text(_, runs) = state.annotations.first(where: { $0.id == id })!.geometry else {
            return XCTFail("expected text geometry")
        }
        XCTAssertEqual(runs.map(\.fontSize), [22, 22])
        // Per-run bold is preserved (only font size was changed).
        XCTAssertEqual(runs.map(\.isBold), [false, true])
    }

    @MainActor
    func test_updateSelectedTextRuns_setsUniformColorAndBold() {
        let (state, id) = makeState(runs: [run("A", size: 12), run("B", size: 30, bold: true)])
        let red = SerializableColor(.systemRed)
        state.updateSelectedTextRuns { runs in for i in runs.indices { runs[i].color = red; runs[i].isBold = false } }
        guard case let .text(_, runs) = state.annotations.first(where: { $0.id == id })!.geometry else {
            return XCTFail("expected text geometry")
        }
        XCTAssertTrue(runs.allSatisfy { $0.color == red })
        XCTAssertTrue(runs.allSatisfy { !$0.isBold })
    }

    @MainActor
    func test_updateSelectedTextRuns_noopForNonText() {
        let size = CGSize(width: 20, height: 20)
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.white.set(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill(); img.unlockFocus()
        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let state = EditorState(sourceImage: cg, sourceURL: nil)
        let rect = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                              style: Style(strokeColor: SerializableColor(.black), strokeWidth: 2))
        state.annotations = [rect]
        state.selectOnly(rect.id)
        state.updateSelectedTextRuns { runs in runs.removeAll() }  // must not touch a non-text object
        if case .rectangle = state.annotations[0].geometry {} else { XCTFail("rectangle geometry should be untouched") }
    }
}
