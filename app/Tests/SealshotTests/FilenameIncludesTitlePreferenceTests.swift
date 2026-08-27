import XCTest
@testable import Sealshot

/// "Include title & app in filename" now governs ALL captures (not just
/// encrypted ones): default ON (matching historic plaintext naming), with a
/// privacy default of OFF applied when Enhanced Security is enabled and the
/// user never chose explicitly.
final class FilenameIncludesTitlePreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.filename.title.\(UUID().uuidString)")!
    }

    func testDefaultsToTrue() {
        let pref = FilenameIncludesTitlePreference(defaults: freshDefaults())
        XCTAssertTrue(pref.enabled)
    }

    func testPersistsFalse() {
        let d = freshDefaults()
        FilenameIncludesTitlePreference(defaults: d).enabled = false
        XCTAssertFalse(FilenameIncludesTitlePreference(defaults: d).enabled)
    }

    func testEncryptionPrivacyDefault_neverSet_encryptionOn_turnsOff() {
        let d = freshDefaults()
        FilenameIncludesTitlePreference.applyEncryptionPrivacyDefault(
            encryptionEnabled: true, defaults: d)
        XCTAssertFalse(FilenameIncludesTitlePreference(defaults: d).enabled)
    }

    func testEncryptionPrivacyDefault_neverSet_encryptionOff_staysOn() {
        let d = freshDefaults()
        FilenameIncludesTitlePreference.applyEncryptionPrivacyDefault(
            encryptionEnabled: false, defaults: d)
        XCTAssertTrue(FilenameIncludesTitlePreference(defaults: d).enabled)
    }

    func testEncryptionPrivacyDefault_respectsExplicitChoice() {
        // The user explicitly opted IN earlier — enabling encryption must not
        // silently override their choice.
        let d = freshDefaults()
        FilenameIncludesTitlePreference(defaults: d).enabled = true
        FilenameIncludesTitlePreference.applyEncryptionPrivacyDefault(
            encryptionEnabled: true, defaults: d)
        XCTAssertTrue(FilenameIncludesTitlePreference(defaults: d).enabled)
    }
}
