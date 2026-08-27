import XCTest
@testable import Sealshot

final class AIFeaturePreferenceTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "ai.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_defaultsOn() {
        let pref = AIFeaturePreference(defaults: freshDefaults())
        XCTAssertTrue(pref.enabled, "AI features default ON (on-device, no privacy cost)")
    }

    func test_persistsToggle() {
        let d = freshDefaults()
        let pref = AIFeaturePreference(defaults: d)
        pref.enabled = false
        XCTAssertFalse(AIFeaturePreference(defaults: d).enabled)
        pref.enabled = true
        XCTAssertTrue(AIFeaturePreference(defaults: d).enabled)
    }
}
