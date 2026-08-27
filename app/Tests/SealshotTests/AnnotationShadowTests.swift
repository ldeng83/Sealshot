import XCTest
import CoreGraphics
@testable import Sealshot

final class AnnotationShadowTests: XCTestCase {
    func testOffsetMirroredForYUpExportContext() {
        XCTAssertEqual(cgShadowOffset(CGSize(width: 3, height: 5), yDown: true, scale: 1),
                       CGSize(width: 3, height: 5))
        XCTAssertEqual(cgShadowOffset(CGSize(width: 3, height: 5), yDown: false, scale: 1),
                       CGSize(width: 3, height: -5))
    }

    func testOffsetScales() {
        XCTAssertEqual(cgShadowOffset(CGSize(width: 3, height: 5), yDown: true, scale: 2),
                       CGSize(width: 6, height: 10))
    }

    func testOnlyVectorShapesCastShadow() {
        XCTAssertTrue(geometryCastsShadow(.line(start: .zero, end: .zero)))
        XCTAssertTrue(geometryCastsShadow(.text(rect: .zero, runs: [])))
        XCTAssertTrue(geometryCastsShadow(.badge(center: .zero, radius: 1)))
        XCTAssertFalse(geometryCastsShadow(.blur(region: .rect(.zero))))
        XCTAssertFalse(geometryCastsShadow(.image(rect: .zero, assetID: "x")))
    }
}
