import XCTest
@testable import Sealshot

@MainActor
final class RelockControllerTests: XCTestCase {
    func testSystemEventLocksWhenEnabledAndUnlocked() {
        var locked = false
        let c = RelockController(isEnabledAndUnlocked: { true }, lock: { locked = true })
        c.handleSystemLockEvent()
        XCTAssertTrue(locked)
    }
    func testSystemEventIgnoredWhenNotEnabled() {
        var locked = false
        let c = RelockController(isEnabledAndUnlocked: { false }, lock: { locked = true })
        c.handleSystemLockEvent()
        XCTAssertFalse(locked)
    }
}
