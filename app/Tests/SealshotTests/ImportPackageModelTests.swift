import XCTest
@testable import Sealshot

@MainActor
final class ImportPackageModelTests: XCTestCase {
    func testCanSubmitRequiresPassphraseAndNotWorking() {
        let m = ImportPackageModel(hint: "pet", createdAt: Date(timeIntervalSince1970: 0), expiresAt: nil)
        XCTAssertFalse(m.canSubmit)                 // empty passphrase
        m.passphrase = "open sesame"
        XCTAssertTrue(m.canSubmit)
        m.setWorking(true)
        XCTAssertFalse(m.canSubmit)                 // working
        m.setWorking(false)
        XCTAssertTrue(m.canSubmit)
    }

    func testHoldsPreUnlockInfo() {
        let created = Date(timeIntervalSince1970: 1000)
        let expires = Date(timeIntervalSince1970: 2000)
        let m = ImportPackageModel(hint: "pet", createdAt: created, expiresAt: expires)
        XCTAssertEqual(m.hint, "pet")
        XCTAssertEqual(m.createdAt, created)
        XCTAssertEqual(m.expiresAt, expires)
    }
}
