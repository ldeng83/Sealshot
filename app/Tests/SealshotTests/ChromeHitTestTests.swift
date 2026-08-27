import XCTest
@testable import Sealshot

final class ChromeHitTestTests: XCTestCase {

    func test_hit_insideHandleSquare_returnsHandle() {
        let positions: [(AnnotationHandle, CGPoint)] = [(.topLeft, CGPoint(x: 100, y: 100))]
        let h = hitTestHandlePositions(positions, at: CGPoint(x: 104, y: 96), handleSize: 12)
        XCTAssertEqual(h, .topLeft)
    }

    func test_miss_outsideHandleSquare_returnsNil() {
        let positions: [(AnnotationHandle, CGPoint)] = [(.topLeft, CGPoint(x: 100, y: 100))]
        XCTAssertNil(hitTestHandlePositions(positions, at: CGPoint(x: 120, y: 120), handleSize: 12))
    }

    func test_firstMatchWins_whenOverlapping() {
        let positions: [(AnnotationHandle, CGPoint)] = [
            (.top, CGPoint(x: 50, y: 50)),
            (.topLeft, CGPoint(x: 52, y: 52)),
        ]
        XCTAssertEqual(hitTestHandlePositions(positions, at: CGPoint(x: 51, y: 51), handleSize: 12), .top)
    }

    func test_grabSize_isConstantScreenSize_regardlessOfProjection() {
        // A 12pt screen grab hits a point 5pt away from the handle center at ANY zoom,
        // because positions+point+size are all already in screen space.
        let positions: [(AnnotationHandle, CGPoint)] = [(.bottomRight, CGPoint(x: 200, y: 200))]
        XCTAssertEqual(hitTestHandlePositions(positions, at: CGPoint(x: 205, y: 195), handleSize: 12), .bottomRight)
    }

    func test_screenRotatePosition_sitsConstantOffsetAboveTopCenter() {
        let p = screenRotatePosition(topCenterScreen: CGPoint(x: 80, y: 120), offset: 32)
        XCTAssertEqual(p.x, 80, accuracy: 0.0001)
        XCTAssertEqual(p.y, 88, accuracy: 0.0001)   // 120 - 32 (top-left/flipped origin)
    }
}
