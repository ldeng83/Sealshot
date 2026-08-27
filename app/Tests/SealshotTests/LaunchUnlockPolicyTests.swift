import XCTest
@testable import Sealshot

final class LaunchUnlockPolicyTests: XCTestCase {
    func testDefaultPreferenceKeepsTheAppLocked() {
        XCTAssertFalse(LaunchUnlockPolicy.shouldUnlockAtLaunch(
            encryptionEnabled: true, identityAvailable: true, locksAtLaunch: true))
    }

    func testOptedOutUnlocksWhenTheKeyIsReachable() {
        XCTAssertTrue(LaunchUnlockPolicy.shouldUnlockAtLaunch(
            encryptionEnabled: true, identityAvailable: true, locksAtLaunch: false))
    }

    /// Post-lockout / keychain-reset state: attempting a silent unlock would
    /// fail anyway. Declining keeps the lock screen up so it can offer the
    /// recovery path instead of dead-ending.
    func testUnreachableIdentityStaysLocked() {
        XCTAssertFalse(LaunchUnlockPolicy.shouldUnlockAtLaunch(
            encryptionEnabled: true, identityAvailable: false, locksAtLaunch: false))
    }

    func testEncryptionOffIsANoOp() {
        XCTAssertFalse(LaunchUnlockPolicy.shouldUnlockAtLaunch(
            encryptionEnabled: false, identityAvailable: true, locksAtLaunch: false))
    }
}
