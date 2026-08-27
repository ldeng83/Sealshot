import XCTest
@testable import Sealshot

final class ChromeProjectionTests: XCTestCase {

    func test_identity_roundTrips() {
        let p = ChromeProjection.identity
        let pt = CGPoint(x: 123, y: 45)
        XCTAssertEqual(p.image(fromScreen: p.screen(fromImage: pt)).x, pt.x, accuracy: 0.0001)
        XCTAssertEqual(p.image(fromScreen: p.screen(fromImage: pt)).y, pt.y, accuracy: 0.0001)
    }

    func test_screen_appliesScaleOriginScroll_thenMagnification() {
        // scale 2 (fit), draw origin (16,16), scrolled (10,0), zoomed 0.5×.
        let p = ChromeProjection(scale: 2, drawOrigin: CGPoint(x: 16, y: 16),
                                 scrollOrigin: CGPoint(x: 10, y: 0), magnification: 0.5)
        // image (100,50) -> canvas (100*2+16, 50*2+16)=(216,116)
        // -> minus scroll (10,0) = (206,116) -> *0.5 = (103,58)
        let s = p.screen(fromImage: CGPoint(x: 100, y: 50))
        XCTAssertEqual(s.x, 103, accuracy: 0.0001)
        XCTAssertEqual(s.y, 58, accuracy: 0.0001)
    }

    func test_image_fromScreen_isInverse_atArbitraryParams() {
        let p = ChromeProjection(scale: 1.7, drawOrigin: CGPoint(x: 16, y: 16),
                                 scrollOrigin: CGPoint(x: 33, y: 12), magnification: 0.3)
        let pt = CGPoint(x: 640, y: 480)
        let back = p.image(fromScreen: p.screen(fromImage: pt))
        XCTAssertEqual(back.x, pt.x, accuracy: 0.001)
        XCTAssertEqual(back.y, pt.y, accuracy: 0.001)
    }

    func test_screenLength_scalesByScaleAndMagnification() {
        let p = ChromeProjection(scale: 2, drawOrigin: .zero, scrollOrigin: .zero, magnification: 0.5)
        // 10 image units * 2 * 0.5 = 10 screen pts
        XCTAssertEqual(p.screenLength(10), 10, accuracy: 0.0001)
    }

    func test_screenRect_projectsOriginAndSize() {
        let p = ChromeProjection(scale: 2, drawOrigin: CGPoint(x: 16, y: 16),
                                 scrollOrigin: .zero, magnification: 0.5)
        let r = p.screen(fromImage: CGRect(x: 10, y: 10, width: 20, height: 40))
        // origin image(10,10)->canvas(36,36)->*0.5=(18,18); size 20*2*0.5=20, 40*2*0.5=40
        XCTAssertEqual(r.origin.x, 18, accuracy: 0.0001)
        XCTAssertEqual(r.origin.y, 18, accuracy: 0.0001)
        XCTAssertEqual(r.width, 20, accuracy: 0.0001)
        XCTAssertEqual(r.height, 40, accuracy: 0.0001)
    }

    func test_screen_appliesViewportOrigin_andInverseRemovesIt() {
        // A legacy scroller can move/shrink the clip view inside the chrome
        // overlay. Projection coordinates are clip-local, so they must be
        // translated into overlay space by the clip viewport's origin.
        let p = ChromeProjection(scale: 2, drawOrigin: CGPoint(x: 16, y: 16),
                                 scrollOrigin: CGPoint(x: 10, y: 4), magnification: 0.5,
                                 viewportOrigin: CGPoint(x: 7, y: 11))
        let imagePoint = CGPoint(x: 100, y: 50)
        let screenPoint = p.screen(fromImage: imagePoint)

        XCTAssertEqual(screenPoint.x, 110, accuracy: 0.0001)
        XCTAssertEqual(screenPoint.y, 67, accuracy: 0.0001)
        XCTAssertEqual(p.image(fromScreen: screenPoint).x, imagePoint.x, accuracy: 0.0001)
        XCTAssertEqual(p.image(fromScreen: screenPoint).y, imagePoint.y, accuracy: 0.0001)
    }

    func test_affineProjectionHandlesIndependentViewAxisScales() {
        let canvasToScreen = CGAffineTransform(
            a: 1, b: 0,
            c: 0, d: 220.0 / 203.0,
            tx: 6, ty: 12
        )
        let p = ChromeProjection(scale: 1, drawOrigin: CGPoint(x: 16, y: 16),
                                 canvasToScreen: canvasToScreen)
        let imageRect = CGRect(x: 0, y: 0, width: 300, height: 200)
        let screenRect = p.screen(fromImage: imageRect)

        XCTAssertEqual(screenRect.minX, 22, accuracy: 0.0001)
        XCTAssertEqual(screenRect.minY, 12 + 16 * 220.0 / 203.0, accuracy: 0.0001)
        XCTAssertEqual(screenRect.width, 300, accuracy: 0.0001)
        XCTAssertEqual(screenRect.height, 200 * 220.0 / 203.0, accuracy: 0.0001)

        let imagePoint = CGPoint(x: 147, y: 83)
        let roundTrip = p.image(fromScreen: p.screen(fromImage: imagePoint))
        XCTAssertEqual(roundTrip.x, imagePoint.x, accuracy: 0.0001)
        XCTAssertEqual(roundTrip.y, imagePoint.y, accuracy: 0.0001)
    }
}
