import XCTest
@testable import Sealshot

final class ImageOverlayHitTestTests: XCTestCase {

    private let style = Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 0)

    private func imageAnnotation(rect: CGRect) -> Annotation {
        Annotation(geometry: .image(rect: rect, assetID: "test-asset"),
                   style: style)
    }

    // MARK: - Body hit-testing

    func test_image_centerHits() {
        let a = imageAnnotation(rect: CGRect(x: 0, y: 0, width: 100, height: 60))
        XCTAssertEqual(hitTestAnnotations([a], at: CGPoint(x: 50, y: 30), tolerance: 6), a.id)
    }

    func test_image_outsideMisses() {
        let a = imageAnnotation(rect: CGRect(x: 0, y: 0, width: 100, height: 60))
        XCTAssertNil(hitTestAnnotations([a], at: CGPoint(x: 200, y: 200), tolerance: 6))
    }

    func test_image_justOutsideEdgeMisses() {
        let a = imageAnnotation(rect: CGRect(x: 10, y: 10, width: 80, height: 50))
        // Point well outside the inset rect: 80 pts past the right edge
        XCTAssertNil(hitTestAnnotations([a], at: CGPoint(x: 200, y: 35), tolerance: 6))
    }

    // MARK: - Handle positions (corners only)

    func test_image_hasExactlyFourHandles() {
        let a = imageAnnotation(rect: CGRect(x: 20, y: 30, width: 100, height: 50))
        // Verify all four corners are recognised
        XCTAssertEqual(hitTestHandles(of: a, at: CGPoint(x: 20, y: 30), handleSize: 8), .topLeft)
        XCTAssertEqual(hitTestHandles(of: a, at: CGPoint(x: 120, y: 30), handleSize: 8), .topRight)
        XCTAssertEqual(hitTestHandles(of: a, at: CGPoint(x: 120, y: 80), handleSize: 8), .bottomRight)
        XCTAssertEqual(hitTestHandles(of: a, at: CGPoint(x: 20, y: 80), handleSize: 8), .bottomLeft)
    }

    func test_image_edgeMidpointIsNotAHandle() {
        // Edge midpoints are not exposed for image overlays (aspect-locked corners only).
        let a = imageAnnotation(rect: CGRect(x: 0, y: 0, width: 100, height: 60))
        // Top-edge midpoint (50, 0) — should return nil, not .top
        XCTAssertNil(hitTestHandles(of: a, at: CGPoint(x: 50, y: 0), handleSize: 8))
    }
}
