import XCTest
@testable import Sealshot

final class EnhanceParamsTests: XCTestCase {
    func testDefaults() {
        let p = EnhanceParams.default
        XCTAssertEqual(p.upscale, .x2)
        XCTAssertEqual(p.sharpness, 25)
        XCTAssertEqual(p.noiseReduction, 0)
        XCTAssertEqual(p.contrast, 0)
    }
    func testScaleFactor() {
        XCTAssertEqual(EnhanceParams(upscale: .off, sharpness: 0, noiseReduction: 0, contrast: 0).scaleFactor, 1)
        XCTAssertEqual(EnhanceParams(upscale: .x2, sharpness: 0, noiseReduction: 0, contrast: 0).scaleFactor, 2)
        XCTAssertEqual(EnhanceParams(upscale: .x4, sharpness: 0, noiseReduction: 0, contrast: 0).scaleFactor, 4)
    }
    func testMappings() {
        let p = EnhanceParams(upscale: .x2, sharpness: 25, noiseReduction: 0, contrast: 0)
        XCTAssertEqual(p.unsharpIntensity, 0.5, accuracy: 0.001)   // 25/100*2
        XCTAssertEqual(p.noiseLevel, 0.0, accuracy: 0.0001)
        XCTAssertEqual(p.contrastFactor, 1.0, accuracy: 0.0001)
        let q = EnhanceParams(upscale: .x4, sharpness: 100, noiseReduction: 100, contrast: 100)
        XCTAssertEqual(q.unsharpIntensity, 2.0, accuracy: 0.001)
        XCTAssertEqual(q.noiseLevel, 0.05, accuracy: 0.0001)
        XCTAssertEqual(q.contrastFactor, 1.3, accuracy: 0.0001)
    }
    func testCodableRoundTrip() throws {
        let p = EnhanceParams(upscale: .x4, sharpness: 60, noiseReduction: 10, contrast: 5)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(EnhanceParams.self, from: data), p)
    }
    func testEquatableDirtyRule() {
        XCTAssertEqual(EnhanceParams.default, EnhanceParams.default)
        XCTAssertNotEqual(EnhanceParams.default,
                          EnhanceParams(upscale: .x2, sharpness: 26, noiseReduction: 0, contrast: 0))
    }
}
