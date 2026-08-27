import XCTest
import RedactionEngineInterface
@testable import Sealshot

final class RedactionEngineDTOTests: XCTestCase {
    final class FakeEngine: RedactionEngine {
        func detect(text: String, entityTypes: [String]) -> [EngineDetection] {
            [EngineDetection(label: "email address", text: "a@b.io", confidence: 0.9)]
        }
    }
    func testFakeEngineReturnsDetections() {
        let out = FakeEngine().detect(text: "mail a@b.io", entityTypes: ["email address"])
        XCTAssertEqual(out, [EngineDetection(label: "email address", text: "a@b.io", confidence: 0.9)])
    }
}
