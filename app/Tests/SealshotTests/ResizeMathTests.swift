import XCTest
@testable import Sealshot

final class ResizeMathTests: XCTestCase {

    private let original = CGSize(width: 2560, height: 1440)

    // MARK: units

    func test_displayValue_roundTrips_allUnits() {
        for unit in ResizeMath.Unit.allCases {
            let display = ResizeMath.displayValue(pixels: 1280, unit: unit,
                                                  originalAxis: original.width, dpi: 144)
            let back = ResizeMath.pixels(fromDisplay: display, unit: unit,
                                         originalAxis: original.width, dpi: 144)
            XCTAssertEqual(back, 1280, accuracy: 0.01, "\(unit) must round-trip")
        }
    }

    func test_percent_isRelativeToOriginalAxis() {
        XCTAssertEqual(ResizeMath.displayValue(pixels: 1280, unit: .percent,
                                               originalAxis: 2560, dpi: 144), 50)
        XCTAssertEqual(ResizeMath.pixels(fromDisplay: 25, unit: .percent,
                                         originalAxis: 1440, dpi: 144), 360)
    }

    func test_physicalUnits_useDPI() {
        XCTAssertEqual(ResizeMath.displayValue(pixels: 288, unit: .inches,
                                               originalAxis: 2560, dpi: 144), 2)
        XCTAssertEqual(ResizeMath.pixels(fromDisplay: 2.54, unit: .centimeters,
                                         originalAxis: 2560, dpi: 100), 100, accuracy: 0.01)
    }

    // MARK: ratio lock

    func test_lockedWidthEdit_scalesHeight() {
        let out = ResizeMath.applyingEdit(enteredPx: 1280, axisIsWidth: true,
                                          lockRatio: true, current: original)
        XCTAssertEqual(out, CGSize(width: 1280, height: 720))
    }

    func test_lockedHeightEdit_scalesWidth() {
        let out = ResizeMath.applyingEdit(enteredPx: 720, axisIsWidth: false,
                                          lockRatio: true, current: original)
        XCTAssertEqual(out, CGSize(width: 1280, height: 720))
    }

    func test_unlockedEdit_changesOneAxisOnly() {
        let out = ResizeMath.applyingEdit(enteredPx: 800, axisIsWidth: true,
                                          lockRatio: false, current: original)
        XCTAssertEqual(out, CGSize(width: 800, height: 1440), "free stretch when unlocked")
    }

    func test_invalidEdit_keepsCurrent() {
        XCTAssertEqual(ResizeMath.applyingEdit(enteredPx: 0, axisIsWidth: true,
                                               lockRatio: true, current: original), original)
        XCTAssertEqual(ResizeMath.applyingEdit(enteredPx: .nan, axisIsWidth: false,
                                               lockRatio: true, current: original), original)
    }

    // MARK: clamps

    func test_clamp_capsUpscaleAtFourTimes_preservingAspect() {
        let out = ResizeMath.clamped(CGSize(width: 2560 * 10, height: 1440 * 10),
                                     original: original)
        XCTAssertEqual(out, CGSize(width: 2560 * 4, height: 1440 * 4))
    }

    func test_clamp_absoluteSideCap_preservesAspect() {
        let tall = CGSize(width: 1000, height: 40_000)
        let out = ResizeMath.clamped(CGSize(width: 4000, height: 160_000), original: tall)
        XCTAssertEqual(out.height, ResizeMath.maxSidePx)
        XCTAssertEqual(out.width / out.height, 4000 / 160_000, accuracy: 0.001)
    }

    func test_clamp_floorsTinySizes() {
        let out = ResizeMath.clamped(CGSize(width: 2, height: 1), original: original)
        XCTAssertEqual(out, CGSize(width: ResizeMath.minSidePx, height: ResizeMath.minSidePx))
    }

    func test_clamp_identityPassesThrough() {
        XCTAssertEqual(ResizeMath.clamped(original, original: original), original)
    }

    // MARK: scale factors

    func test_scaleFactors() {
        let f = ResizeMath.scaleFactors(from: original, to: CGSize(width: 1280, height: 720))
        XCTAssertEqual(f.x, 0.5)
        XCTAssertEqual(f.y, 0.5)
    }
}

extension ResizeMathTests {
    func test_unitSteps() {
        XCTAssertEqual(ResizeMath.unitStep(.pixels), 10)
        XCTAssertEqual(ResizeMath.unitStep(.percent), 1)
        XCTAssertEqual(ResizeMath.unitStep(.inches), 0.1)
        XCTAssertEqual(ResizeMath.unitStep(.centimeters), 0.1)
    }
}
