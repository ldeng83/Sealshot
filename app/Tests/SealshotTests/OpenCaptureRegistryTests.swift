import XCTest
@testable import Sealshot

@MainActor
final class OpenCaptureRegistryTests: XCTestCase {
    func testAddContainsRemove() {
        let reg = OpenCaptureRegistry()
        let u = URL(fileURLWithPath: "/tmp/a.seal")
        XCTAssertFalse(reg.contains(u))
        reg.add(u)
        XCTAssertTrue(reg.contains(u))
        // Path-equality is by standardized path, not URL identity.
        XCTAssertTrue(reg.contains(URL(fileURLWithPath: "/tmp/./a.seal")))
        reg.remove(u)
        XCTAssertFalse(reg.contains(u))
    }
}
