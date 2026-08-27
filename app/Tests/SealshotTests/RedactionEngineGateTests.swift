import XCTest
@testable import Sealshot

final class RedactionEngineGateTests: XCTestCase {
    func testAllTrue_usesEngine() {
        XCTAssertTrue(RedactionEngineGate.shouldUseEngine(appleSilicon: true, aiEnabled: true, modelPresent: true))
    }
    func testAnyFalse_doesNot() {
        XCTAssertFalse(RedactionEngineGate.shouldUseEngine(appleSilicon: false, aiEnabled: true, modelPresent: true))
        XCTAssertFalse(RedactionEngineGate.shouldUseEngine(appleSilicon: true, aiEnabled: false, modelPresent: true))
        XCTAssertFalse(RedactionEngineGate.shouldUseEngine(appleSilicon: true, aiEnabled: true, modelPresent: false))
    }
}
