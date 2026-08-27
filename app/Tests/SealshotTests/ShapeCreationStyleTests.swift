import XCTest
import AppKit
@testable import Sealshot

/// The fill color chosen in a shape tool's panel (`state.shapeFillColor`) seeds
/// newly drawn rectangles/ellipses via `shapeCreationStyle`.
final class ShapeCreationStyleTests: XCTestCase {

    @MainActor
    private func makeState() -> EditorState {
        let size = CGSize(width: 10, height: 10)
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.white.set(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill(); img.unlockFocus()
        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return EditorState(sourceImage: cg, sourceURL: nil)
    }

    @MainActor
    func test_defaultFill_isNil_outlineOnly() {
        let state = makeState()
        XCTAssertNil(state.shapeFillColor)
        XCTAssertNil(shapeCreationStyle(state: state).fillColor,
                     "no default fill → new shapes are outline-only")
    }

    @MainActor
    func test_shapeFillColor_seedsCreationStyle() {
        let state = makeState()
        state.shapeFillColor = .systemBlue
        let fill = shapeCreationStyle(state: state).fillColor
        XCTAssertNotNil(fill, "a chosen tool fill must carry into new shapes")
        // Stored opaque (box opacity is applied at render, not per-style here).
        XCTAssertEqual(fill?.a ?? 0, 1.0, accuracy: 0.001)
    }

    @MainActor
    func test_creationStyle_carriesStrokeDefaults() {
        let state = makeState()
        state.selectedColor = .systemGreen
        state.strokeWidth = 7
        let style = shapeCreationStyle(state: state)
        XCTAssertEqual(style.strokeWidth, 7, accuracy: 0.001)
    }

    @MainActor
    func test_defaultCornerRadius_isToolbarMidpoint() {
        // Rectangles default to a rounded corner (50% of the 0–40 slider).
        XCTAssertEqual(makeState().shapeCornerRadius, 20, accuracy: 0.001)
    }

    @MainActor
    func test_creationStyle_carriesOpacityAndCornerRadius() {
        let state = makeState()
        state.creationOpacity = 0.5
        state.shapeCornerRadius = 12
        let style = shapeCreationStyle(state: state)
        XCTAssertEqual(style.opacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(style.cornerRadius, 12, accuracy: 0.001)
    }

    @MainActor
    func test_strokeCreationStyle_mirrorsArrowLineObjectPanel() {
        let state = makeState()
        state.selectedColor = .systemOrange
        state.strokeWidth = 5
        state.creationOpacity = 0.4
        let style = strokeCreationStyle(state: state)
        XCTAssertEqual(style.strokeWidth, 5, accuracy: 0.001)
        XCTAssertEqual(style.opacity, 0.4, accuracy: 0.001)
        XCTAssertNil(style.fillColor, "arrows/lines have no fill")
    }

    @MainActor
    func test_strokeCreationStyle_arrow_carriesCapsAndDash() {
        let state = makeState()
        state.selectedTool = .arrow
        state.arrowStartCap = .dot
        state.arrowEndCap = .open
        state.dashStyle = .dashed
        let style = strokeCreationStyle(state: state)
        XCTAssertEqual(style.startCap, .dot)
        XCTAssertEqual(style.endCap, .open)
        XCTAssertEqual(style.dashStyle, .dashed)
    }

    @MainActor
    func test_strokeCreationStyle_line_hasNoCaps_butCarriesDash() {
        let state = makeState()
        state.selectedTool = .line
        state.dashStyle = .dotted
        let style = strokeCreationStyle(state: state)
        XCTAssertEqual(style.startCap, .none, "lines never carry arrowheads")
        XCTAssertEqual(style.endCap, .none, "lines never carry arrowheads")
        XCTAssertEqual(style.dashStyle, .dotted)
    }

    @MainActor
    func test_dashStyle_isPerTool() {
        let state = makeState()
        state.selectedTool = .arrow
        state.dashStyle = .dashed
        state.selectedTool = .line
        XCTAssertEqual(state.dashStyle, .solid, "Line keeps its own dash, unaffected by Arrow")
        state.dashStyle = .dotted
        state.selectedTool = .arrow
        XCTAssertEqual(state.dashStyle, .dashed, "Arrow remembers its own dash")
    }

    @MainActor
    func test_badgeCreationStyle_mirrorsBadgeObjectPanel() {
        let state = makeState()
        state.badgeFillColor = .systemBlue
        state.badgeNumberColor = .white
        state.creationOpacity = 0.6
        let style = badgeCreationStyle(state: state)
        XCTAssertNotNil(style.fillColor, "badge has a fill (default systemRed)")
        XCTAssertEqual(style.opacity, 0.6, accuracy: 0.001)
        XCTAssertEqual(style.strokeWidth, 0, accuracy: 0.001)
    }

    @MainActor
    func test_textCreationStyle_carriesOpacityAndFont() {
        let state = makeState()
        state.textFontSize = 28
        state.textIsBold = true
        state.creationOpacity = 0.7
        let style = textCreationStyle(state: state)
        XCTAssertEqual(style.opacity, 0.7, accuracy: 0.001)
        XCTAssertEqual(style.fontSize, 28, accuracy: 0.001)
        XCTAssertTrue(style.isBold)
    }

    @MainActor
    func test_creationDefaults_match_objectPanelDefaults() {
        // Out of the box, a freshly created shape's style should equal the
        // creation defaults so the no-selection panel and the object panel
        // describe the same shape.
        let state = makeState()
        let style = shapeCreationStyle(state: state)
        XCTAssertEqual(style.opacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(style.cornerRadius, 20, accuracy: 0.001)
        XCTAssertNil(style.fillColor)
    }
}
