import XCTest
@testable import Sealshot

final class RedactionEngineLoaderTests: XCTestCase {
    func testNilModelPath_returnsNil() {
        XCTAssertNil(RedactionEngineLoader().engine(modelPath: nil))
    }
    func testMissingModelFile_returnsNil() {
        XCTAssertNil(RedactionEngineLoader().engine(modelPath: "/no/such/model"))
    }
    func testIsAppleSilicon_matchesArch() {
        #if arch(arm64)
        XCTAssertTrue(RedactionEngineLoader.isAppleSilicon)
        #else
        XCTAssertFalse(RedactionEngineLoader.isAppleSilicon)
        #endif
    }
}
