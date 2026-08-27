import XCTest
@testable import Sealshot

/// `ImageZoomMemory` stores whole-image zoom PER capture (keyed by file path),
/// so one image's zoom never bleeds into another.
final class ImageZoomMemoryTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ImageZoomMemoryTests-\(UUID().uuidString)")!
    }
    private let a = URL(fileURLWithPath: "/caps/a.seal")
    private let b = URL(fileURLWithPath: "/caps/b.seal")

    func test_missing_isNil() {
        XCTAssertNil(ImageZoomMemory.load(for: a, freshDefaults()))
    }

    func test_roundTrip() {
        let d = freshDefaults()
        ImageZoomMemory.store(0.5, for: a, d)
        XCTAssertEqual(ImageZoomMemory.load(for: a, d), 0.5)
    }

    func test_perImageIndependence() {
        let d = freshDefaults()
        ImageZoomMemory.store(0.5, for: a, d)
        ImageZoomMemory.store(2.0, for: b, d)
        XCTAssertEqual(ImageZoomMemory.load(for: a, d), 0.5)
        XCTAssertEqual(ImageZoomMemory.load(for: b, d), 2.0)
    }

    func test_storingOneImage_doesNotAffectAnother() {
        let d = freshDefaults()
        ImageZoomMemory.store(0.5, for: a, d)
        XCTAssertNil(ImageZoomMemory.load(for: b, d),
                     "a different image must not inherit another image's zoom")
    }

    func test_unsavedCapture_notRemembered() {
        let d = freshDefaults()
        ImageZoomMemory.store(0.5, for: nil, d)
        XCTAssertNil(ImageZoomMemory.load(for: nil, d))
    }

    func test_clampedOnWrite() {
        let d = freshDefaults()
        ImageZoomMemory.store(999, for: a, d)
        XCTAssertEqual(ImageZoomMemory.load(for: a, d), EditorCanvasScrollView.manualMaxZoom)
    }
}
