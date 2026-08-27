import XCTest
@testable import Sealshot

@MainActor
final class EditAdoptsDefaultIntegrationTests: XCTestCase {
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

    private func state() -> EditorState {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return EditorState(sourceImage: ctx.makeImage()!, sourceURL: nil)
    }

    func testEditingSelectedRectangleUpdatesRectangleDefault() {
        let s = state()
        let id = UUID()
        s.annotations.append(Annotation(id: id, geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 4, height: 4)),
                                        style: Style(strokeColor: SerializableColor(.red), strokeWidth: 4)))
        s.updateStyle(id: id) { $0.strokeWidth = 12; $0.strokeColor = SerializableColor(.green) }
        s.selectedTool = .rectangle
        XCTAssertEqual(s.strokeWidth, 12, "rectangle tool default width adopted")
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(.green))
        XCTAssertEqual(shapeCreationStyle(state: s).strokeWidth, 12, "next rectangle inherits it")
    }

    func testEditingImageObjectAdoptsNothing() {
        let s = state()
        let id = UUID()
        s.selectedColor = .red
        s.annotations.append(Annotation(id: id, geometry: .image(rect: CGRect(x: 0, y: 0, width: 4, height: 4), assetID: "a"),
                                        style: Style(strokeColor: SerializableColor(.blue), strokeWidth: 4)))
        s.updateStyle(id: id) { $0.opacity = 0.3 }
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(.red), "image edit adopts no default")
    }
}
