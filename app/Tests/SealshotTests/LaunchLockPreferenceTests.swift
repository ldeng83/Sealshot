import XCTest
@testable import Sealshot

final class LaunchLockPreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "launch-lock-\(UUID().uuidString)")!
    }

    func testDefaultLocksAtLaunch() {
        let d = freshDefaults()
        XCTAssertTrue(LaunchLockPreference(defaults: d).locksAtLaunch,
                      "a Mac that has never seen this setting must lock at launch")
    }

    func testPersistsBothWays() {
        let d = freshDefaults()
        let p = LaunchLockPreference(defaults: d)
        p.locksAtLaunch = false
        XCTAssertFalse(LaunchLockPreference(defaults: d).locksAtLaunch)
        p.locksAtLaunch = true
        XCTAssertTrue(LaunchLockPreference(defaults: d).locksAtLaunch)
    }

    /// The stored key is the OPT-OUT, so a missing value means "lock". Storing
    /// the setting the other way round would silently flip every existing
    /// install to unlocked-at-launch on upgrade — the whole reason for the
    /// inversion, and worth pinning against a well-meaning refactor.
    func testStoresTheOptOutNotThePositive() {
        let d = freshDefaults()
        let p = LaunchLockPreference(defaults: d)
        XCTAssertNil(d.object(forKey: "EncryptionSkipLaunchLock"),
                     "default state writes nothing")
        p.locksAtLaunch = false
        XCTAssertEqual(d.bool(forKey: "EncryptionSkipLaunchLock"), true)
        p.locksAtLaunch = true
        XCTAssertEqual(d.bool(forKey: "EncryptionSkipLaunchLock"), false)
    }
}
