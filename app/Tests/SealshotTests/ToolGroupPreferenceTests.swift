import XCTest
@testable import Sealshot

final class ToolGroupPreferenceTests: XCTestCase {

    private let shape = EditorToolbarBuilder.shapeGroup

    /// Line and Arrow are no longer a toolbar group, so there's only one real
    /// grouped pair left (shapes). A synthetic second group lets us still verify
    /// the preference store is generic and keeps groups independent.
    private let other = ToolGroup(
        id: "test.other",
        members: [
            .init(tool: .badge, symbol: "1.circle", label: "Step"),
            .init(tool: .text, symbol: "textformat", label: "Text"),
        ],
        defaultTool: .badge
    )

    func testLast_unset_defaultsToGroupDefault() {
        let defaults = makeDefaults()
        XCTAssertEqual(ToolGroupPreference.last(other, defaults), .badge)
        XCTAssertEqual(ToolGroupPreference.last(shape, defaults), .rectangle)
    }

    func testStore_thenLoad_roundTrips() {
        let defaults = makeDefaults()
        ToolGroupPreference.store(.text, in: other, defaults)
        ToolGroupPreference.store(.ellipse, in: shape, defaults)
        XCTAssertEqual(ToolGroupPreference.last(other, defaults), .text)
        XCTAssertEqual(ToolGroupPreference.last(shape, defaults), .ellipse)
    }

    func testGroups_areStoredIndependently() {
        let defaults = makeDefaults()
        ToolGroupPreference.store(.text, in: other, defaults)
        // Storing in the shape group must not disturb the other group's choice.
        ToolGroupPreference.store(.ellipse, in: shape, defaults)
        XCTAssertEqual(ToolGroupPreference.last(other, defaults), .text)
    }

    func testStore_toolOutsideGroup_isIgnored() {
        let defaults = makeDefaults()
        ToolGroupPreference.store(.text, in: other, defaults)
        ToolGroupPreference.store(.rectangle, in: other, defaults)  // not a member
        XCTAssertEqual(ToolGroupPreference.last(other, defaults), .text)
    }

    func testLast_garbageValue_fallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("not-a-tool", forKey: "toolGroup.test.other.last")
        XCTAssertEqual(ToolGroupPreference.last(other, defaults), .badge)
    }

    /// Isolated, empty defaults so tests never touch the real domain.
    private func makeDefaults() -> UserDefaults {
        let suite = "ToolGroupPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
