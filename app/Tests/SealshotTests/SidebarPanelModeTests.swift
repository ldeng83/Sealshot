import XCTest
@testable import Sealshot

final class SidebarPanelModeTests: XCTestCase {

    func testToggleFlipsBetweenPropertiesAndInfo() {
        XCTAssertEqual(SidebarPanelMode.properties.toggledInfo(), .info)
        XCTAssertEqual(SidebarPanelMode.info.toggledInfo(), .properties)
    }

    func testIsInfo() {
        XCTAssertTrue(SidebarPanelMode.info.isInfo)
        XCTAssertFalse(SidebarPanelMode.properties.isInfo)
        XCTAssertFalse(SidebarPanelMode.imageTextSearch.isInfo)
        XCTAssertTrue(SidebarPanelMode.imageTextSearch.isImageTextSearch)
    }

    func testToolSelectAlwaysExitsInfo() {
        // Info now behaves like a peer of the tools: selecting ANY tool exits
        // Info (including the no-properties Hand/pan tool).
        XCTAssertEqual(SidebarPanelMode.info.afterToolSelected(), .properties)
    }

    func testToolSelectLeavesPropertiesUnchanged() {
        XCTAssertEqual(SidebarPanelMode.properties.afterToolSelected(), .properties)
    }

    func testToolSelectExitsImageTextSearch() {
        XCTAssertEqual(SidebarPanelMode.imageTextSearch.afterToolSelected(), .properties)
    }

    // Info is DISPLAYED only when Info mode is on AND nothing overrides it:
    // a selection or a redaction review shows that content instead.
    func testShowsInfo_onlyWhenInfoModeAndNothingSelectedOrReviewing() {
        XCTAssertTrue(SidebarPanelMode.info.showsInfo(selectionCount: 0, reviewingRedactions: false))
    }

    func testShowsInfo_falseWhenObjectSelected() {
        XCTAssertFalse(SidebarPanelMode.info.showsInfo(selectionCount: 1, reviewingRedactions: false))
        XCTAssertFalse(SidebarPanelMode.info.showsInfo(selectionCount: 3, reviewingRedactions: false))
    }

    func testShowsInfo_falseWhenReviewingRedactions() {
        XCTAssertFalse(SidebarPanelMode.info.showsInfo(selectionCount: 0, reviewingRedactions: true))
    }

    func testShowsInfo_falseInPropertiesMode() {
        XCTAssertFalse(SidebarPanelMode.properties.showsInfo(selectionCount: 0, reviewingRedactions: false))
    }

    func testPreferenceDefaultsToProperties() {
        let d = UserDefaults(suiteName: "SidebarPanelModeTests.default")!
        d.removePersistentDomain(forName: "SidebarPanelModeTests.default")
        XCTAssertEqual(SidebarPanelModePreference.load(d), .properties)
    }

    func testPreferenceRoundTrips() {
        let d = UserDefaults(suiteName: "SidebarPanelModeTests.roundtrip")!
        d.removePersistentDomain(forName: "SidebarPanelModeTests.roundtrip")
        SidebarPanelModePreference.store(.info, into: d)
        XCTAssertEqual(SidebarPanelModePreference.load(d), .info)
        SidebarPanelModePreference.store(.properties, into: d)
        XCTAssertEqual(SidebarPanelModePreference.load(d), .properties)
    }

    func testPreferenceFallsBackToPropertiesOnGarbage() {
        let d = UserDefaults(suiteName: "SidebarPanelModeTests.garbage")!
        d.removePersistentDomain(forName: "SidebarPanelModeTests.garbage")
        d.set("nonsense", forKey: "sidebarPanelMode")
        XCTAssertEqual(SidebarPanelModePreference.load(d), .properties)
    }

    func testPreferenceNeverRestoresTransientImageTextSearch() {
        let d = UserDefaults(suiteName: "SidebarPanelModeTests.search")!
        d.removePersistentDomain(forName: "SidebarPanelModeTests.search")
        SidebarPanelModePreference.store(.imageTextSearch, into: d)
        XCTAssertEqual(SidebarPanelModePreference.load(d), .properties)

        d.set(SidebarPanelMode.imageTextSearch.rawValue, forKey: "sidebarPanelMode")
        XCTAssertEqual(SidebarPanelModePreference.load(d), .properties)
    }
}
