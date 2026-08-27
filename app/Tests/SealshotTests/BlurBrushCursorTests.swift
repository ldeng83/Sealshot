import XCTest
import AppKit
@testable import Sealshot

/// The freehand blur brush shows a hollow-ring cursor whose on-screen diameter
/// matches the stroke it will paint: `blurBrushWidth` (image space) scaled by
/// the current zoom. The mapping is floored so a tiny brush is still visible
/// and capped so an extreme zoom can't produce a cursor macOS would clamp
/// (which would misplace the hot spot).
final class BlurBrushCursorTests: XCTestCase {

    func test_diameterEqualsBrushWidthTimesScale() {
        XCTAssertEqual(EditorCanvasView.brushCursorDiameter(brushWidth: 40, scale: 1.0), 40, accuracy: 0.001)
        XCTAssertEqual(EditorCanvasView.brushCursorDiameter(brushWidth: 40, scale: 0.5), 20, accuracy: 0.001)
    }

    func test_diameterFlooredToMinimumWhenTiny() {
        // 8 image px at 10% zoom = 0.8pt — too small to see; floored.
        let d = EditorCanvasView.brushCursorDiameter(brushWidth: 8, scale: 0.1)
        XCTAssertGreaterThanOrEqual(d, EditorCanvasView.brushCursorMinDiameter)
        XCTAssertEqual(d, EditorCanvasView.brushCursorMinDiameter, accuracy: 0.001)
    }

    func test_diameterCappedAtMaximum() {
        let d = EditorCanvasView.brushCursorDiameter(brushWidth: 120, scale: 5.0)
        XCTAssertEqual(d, EditorCanvasView.brushCursorMaxDiameter, accuracy: 0.001)
    }
}
