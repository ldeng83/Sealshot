import XCTest
@testable import Sealshot

/// Step (badge) sizing: a range and default scaled to the image, and a size
/// remembered per image — the last one set, by slider or handle drag.
@MainActor
final class BadgeSizingTests: XCTestCase {

    private func state(width: Int, height: Int) -> EditorState {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditorState(sourceImage: ctx.makeImage()!, sourceURL: nil)
    }

    private func badge(radius: CGFloat) -> Annotation {
        Annotation(geometry: .badge(center: CGPoint(x: 50, y: 50), radius: radius),
                   style: Style(strokeColor: SerializableColor(r: 1, g: 1, b: 1, a: 1), strokeWidth: 0))
    }

    // MARK: Range and default

    func testRangeScalesWithTheImage() {
        let retina = BadgeSizing.range(for: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(retina.lowerBound, 8)
        XCTAssertEqual(retina.upperBound, 216, accuracy: 0.001)
        let hd = BadgeSizing.range(for: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(hd.upperBound, 108, accuracy: 0.001)
    }

    func testRangeNeverBelowTheOldMax() {
        XCTAssertEqual(BadgeSizing.range(for: CGSize(width: 300, height: 200)).upperBound, 60)
    }

    func testDefaultScalesWithTheImageWithinRange() {
        XCTAssertEqual(BadgeSizing.defaultRadius(for: CGSize(width: 3840, height: 2160)), 64.8, accuracy: 0.001)
        XCTAssertEqual(BadgeSizing.defaultRadius(for: CGSize(width: 300, height: 200)), 8, "clamped to the minimum")
    }

    // MARK: Per-image memory

    func testNewImageStartsAtItsDefault() {
        let s = state(width: 3840, height: 2160)
        XCTAssertEqual(s.badgeRadius, 64.8, accuracy: 0.001)
    }

    func testImageWithStepsContinuesFromItsLastStep() {
        let s = state(width: 3840, height: 2160)
        s.annotations = [badge(radius: 40), badge(radius: 70)]
        XCTAssertEqual(s.badgeRadius, 70)
    }

    func testResizingASelectedStepIsRemembered() {
        let s = state(width: 3840, height: 2160)
        s.annotations = [badge(radius: 40), badge(radius: 70)]
        s.updateBadgeRadius(id: s.annotations[0].id, 90)
        XCTAssertEqual(s.badgeRadius, 90, "the last size set wins, not the last step's")
    }

    func testSwitchingToANewImageDoesNotCarryTheSize() {
        let a = state(width: 3840, height: 2160)
        a.badgeRadius = 120
        let b = state(width: 1920, height: 1080)
        b.adoptCreationSettings(from: a)
        XCTAssertEqual(b.badgeRadius, BadgeSizing.defaultRadius(for: CGSize(width: 1920, height: 1080)),
                       accuracy: 0.001)
    }

    func testRevertKeepsTheImagesChosenSize() {
        let s = state(width: 3840, height: 2160)
        s.badgeRadius = 120
        XCTAssertEqual(s.revertedToOriginal().badgeRadius, 120)
    }

    func testSizeIsClampedToTheImagesRange() {
        let s = state(width: 1920, height: 1080)
        s.annotations = [badge(radius: 40)]
        s.updateBadgeRadius(id: s.annotations[0].id, 500)
        guard case let .badge(_, r) = s.annotations[0].geometry else { return XCTFail() }
        XCTAssertEqual(r, 108, accuracy: 0.001, "capped at the slider max")
        XCTAssertEqual(s.badgeRadius, 108, accuracy: 0.001)
        s.updateBadgeRadius(id: s.annotations[0].id, 1)
        guard case let .badge(_, r2) = s.annotations[0].geometry else { return XCTFail() }
        XCTAssertEqual(r2, 8, "capped at the slider min")
    }
}
