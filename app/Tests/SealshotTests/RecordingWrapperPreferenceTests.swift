import XCTest
@testable import Sealshot

/// Which container a finished recording lands in. Stored as the opt-out so an
/// install that has never seen the setting keeps writing packages — the value
/// decides where gigabytes of someone's recording go, so the default must not
/// be reachable by accident.
final class RecordingWrapperPreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "rec-wrapper-\(UUID().uuidString)")!
    }

    func testDefaultsToTheSealPackage() {
        XCTAssertEqual(RecordingWrapperPreference(defaults: freshDefaults()).wrapper, .sealPackage)
    }

    func testPersistsBothWays() {
        let d = freshDefaults()
        let pref = RecordingWrapperPreference(defaults: d)
        pref.wrapper = .plainMovie
        XCTAssertEqual(RecordingWrapperPreference(defaults: d).wrapper, .plainMovie)
        pref.wrapper = .sealPackage
        XCTAssertEqual(RecordingWrapperPreference(defaults: d).wrapper, .sealPackage)
    }

    /// The stored key is the OPT-OUT. Storing it the other way round would flip
    /// every existing install to plain movies on upgrade — unencrypting their
    /// recordings without asking.
    func testStoresTheOptOutNotThePositive() {
        let d = freshDefaults()
        let pref = RecordingWrapperPreference(defaults: d)
        XCTAssertNil(d.object(forKey: "RecordingSavesPlainMovie"), "default writes nothing")
        pref.wrapper = .plainMovie
        XCTAssertEqual(d.bool(forKey: "RecordingSavesPlainMovie"), true)
        pref.wrapper = .sealPackage
        XCTAssertEqual(d.bool(forKey: "RecordingSavesPlainMovie"), false)
    }
}
