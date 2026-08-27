import XCTest
@testable import Sealshot

final class GeometryToolTests: XCTestCase {
    func testMapsDrawingGeometriesToTools() {
        XCTAssertEqual(geometryTool(.rectangle(rect: .zero)), .rectangle)
        XCTAssertEqual(geometryTool(.ellipse(rect: .zero)), .ellipse)
        XCTAssertEqual(geometryTool(.arrow(start: .zero, end: .zero)), .arrow)
        XCTAssertEqual(geometryTool(.line(start: .zero, end: .zero)), .line)
        XCTAssertEqual(geometryTool(.text(rect: .zero, runs: [])), .text)
        XCTAssertEqual(geometryTool(.badge(center: .zero, radius: 1)), .badge)
        XCTAssertEqual(geometryTool(.pen(points: [])), .pen)
    }
    func testExcludedGeometriesReturnNil() {
        XCTAssertNil(geometryTool(.blur(region: .rect(.zero))))
        XCTAssertNil(geometryTool(.image(rect: .zero, assetID: "x")))
        XCTAssertNil(geometryTool(.cut(rect: .zero)))
    }
}
