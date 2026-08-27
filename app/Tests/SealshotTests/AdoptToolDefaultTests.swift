import XCTest
@testable import Sealshot

@MainActor
final class AdoptToolDefaultTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearShadowDefaults()
    }
    override func tearDown() {
        clearShadowDefaults()
        super.tearDown()
    }
    private func clearShadowDefaults() {
        for tool in EditorTool.allCases {
            UserDefaults.standard.removeObject(forKey: "annotationShadowDefault." + tool.rawValue)
            for role in ToolColorRole.allCases {   // adoption also persists per-tool colors now
                UserDefaults.standard.removeObject(
                    forKey: "annotationColorDefault.\(tool.rawValue).\(role.rawValue)")
            }
        }
    }

    private func state() -> EditorState {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return EditorState(sourceImage: ctx.makeImage()!, sourceURL: nil)
    }

    func testRectangleAdoptsAllFields() {
        let s = state()
        var style = Style(strokeColor: SerializableColor(.green), strokeWidth: 9,
                          opacity: 0.5, fillColor: SerializableColor(.blue), cornerRadius: 7)
        var sh = ShadowStyle.pronounced; sh.blur = 3; style.shadow = sh
        s.adoptStyleAsToolDefault(style, for: .rectangle)
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(.green))
        XCTAssertEqual(s.shapeFillColor.map { SerializableColor($0) }, SerializableColor(.blue))
        s.selectedTool = .rectangle
        XCTAssertEqual(s.strokeWidth, 9)
        XCTAssertEqual(s.creationOpacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.shapeCornerRadius, 7)
        XCTAssertEqual(s.shadowDefault(for: .rectangle).blur, 3)
    }

    func testEllipseDoesNotTouchCornerRadius() {
        let s = state()
        s.shapeCornerRadius = 20
        let style = Style(strokeColor: SerializableColor(.red), strokeWidth: 4, cornerRadius: 99)
        s.adoptStyleAsToolDefault(style, for: .ellipse)
        XCTAssertEqual(s.shapeCornerRadius, 20, "ellipse has no corner radius default")
    }

    func testArrowAdoptsCapsAndDash() {
        let s = state()
        let style = Style(strokeColor: SerializableColor(.red), strokeWidth: 4,
                          startCap: .dot, endCap: .bar, dashStyle: .dashed)
        s.adoptStyleAsToolDefault(style, for: .arrow)
        XCTAssertEqual(s.arrowStartCap, .dot)
        XCTAssertEqual(s.arrowEndCap, .bar)
        s.selectedTool = .arrow
        XCTAssertEqual(s.dashStyle, .dashed)
    }

    func testPerToolWidthIsolation() {
        let s = state()
        s.selectedTool = .arrow; s.strokeWidth = 4
        let lineStyle = Style(strokeColor: SerializableColor(.red), strokeWidth: 11)
        s.adoptStyleAsToolDefault(lineStyle, for: .line)
        s.selectedTool = .line;  XCTAssertEqual(s.strokeWidth, 11)
        s.selectedTool = .arrow; XCTAssertEqual(s.strokeWidth, 4, "line edit must not change arrow width")
    }

    func testBadgeAdoptsNumberAndFillColors() {
        let s = state()
        let style = Style(strokeColor: SerializableColor(.white), strokeWidth: 0,
                          fillColor: SerializableColor(.systemTeal))
        s.adoptStyleAsToolDefault(style, for: .badge)
        XCTAssertEqual(SerializableColor(s.badgeNumberColor), SerializableColor(.white))
        XCTAssertEqual(SerializableColor(s.badgeFillColor), SerializableColor(.systemTeal))
    }
}
