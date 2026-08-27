import XCTest
@testable import Sealshot

final class LockScreenModeTests: XCTestCase {
    func testConsistencyStatusMapsToLockScreenMode() {
        let gen = KeyGeneration.make(publicKey: IdentityKey.generate().publicKey)
        XCTAssertEqual(ConsistencyStatus.off.lockScreenMode, .unlock)
        XCTAssertEqual(ConsistencyStatus.consistent(gen).lockScreenMode, .unlock)
        XCTAssertEqual(ConsistencyStatus.recoverable(gen).lockScreenMode, .recovery)
        XCTAssertEqual(ConsistencyStatus.diverged(.noKeyring).lockScreenMode, .diverged)
        XCTAssertEqual(ConsistencyStatus.diverged(.noIdentityNoEscrow(gen)).lockScreenMode, .diverged)
        XCTAssertEqual(
            ConsistencyStatus.diverged(.orphanCapsule(store: "history", stampedGeneration: gen.id)).lockScreenMode,
            .diverged)
    }

    func testConsistencyStatusSettingsSummary() {
        let gen = KeyGeneration.make(publicKey: IdentityKey.generate().publicKey)
        XCTAssertNil(ConsistencyStatus.off.settingsSummary)
        XCTAssertNotNil(ConsistencyStatus.consistent(gen).settingsSummary)
        XCTAssertNotNil(ConsistencyStatus.recoverable(gen).settingsSummary)
        XCTAssertNotNil(ConsistencyStatus.diverged(.noKeyring).settingsSummary)
        // Distinct messaging per state.
        XCTAssertNotEqual(ConsistencyStatus.consistent(gen).settingsSummary,
                          ConsistencyStatus.recoverable(gen).settingsSummary)
    }
}
