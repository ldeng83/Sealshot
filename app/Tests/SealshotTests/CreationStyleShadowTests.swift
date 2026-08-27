import XCTest
@testable import Sealshot

@MainActor
final class CreationStyleShadowTests: XCTestCase {
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
        }
    }

    func testStrokeCreationCarriesPerToolShadow() {
        let state = EditorState(sourceImage: Self.img(), sourceURL: nil)
        state.selectedTool = .line
        var custom = ShadowStyle.pronounced; custom.blur = 1
        state.setShadowDefault(custom, for: .line)
        XCTAssertEqual(strokeCreationStyle(state: state).shadow.blur, 1)
    }

    func testShapeCreationDefaultsToPronounced() {
        let state = EditorState(sourceImage: Self.img(), sourceURL: nil)
        state.selectedTool = .rectangle
        XCTAssertTrue(shapeCreationStyle(state: state).shadow.enabled)
    }

    private static func img() -> CGImage {
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        return ctx.makeImage()!
    }
}
