import XCTest
@testable import Sealshot

final class SidebarRoutingTests: XCTestCase {

    func test_routesToObjectPanelWhenSingleSelected() {
        // A single selection always shows the direct object panel, for any tool.
        XCTAssertEqual(sidebarPanel(tool: .arrow, selectionCount: 1, annotationCount: 1), .object)
        XCTAssertEqual(sidebarPanel(tool: .select, selectionCount: 1, annotationCount: 3), .object)
        XCTAssertEqual(sidebarPanel(tool: .rectangle, selectionCount: 1, annotationCount: 1), .object)
    }

    func test_selectTool_objectsExist_routesToObjectList() {
        // Select tool with objects present but a non-single selection (0 or 2+)
        // shows the layers list.
        XCTAssertEqual(sidebarPanel(tool: .select, selectionCount: 0, annotationCount: 2), .objectList)
        XCTAssertEqual(sidebarPanel(tool: .select, selectionCount: 3, annotationCount: 4), .objectList)
    }

    func test_selectTool_noObjects_routesToToolPanel() {
        XCTAssertEqual(sidebarPanel(tool: .select, selectionCount: 0, annotationCount: 0), .tool(.select))
    }

    func test_nonSelectTool_manySelected_routesToMultiObject() {
        // A non-Select tool with 2+ selected keeps the multi-object summary.
        XCTAssertEqual(sidebarPanel(tool: .arrow, selectionCount: 3, annotationCount: 3), .multiObject)
    }

    func test_routesToToolPanelWhenNothingSelected() {
        XCTAssertEqual(sidebarPanel(tool: .crop, selectionCount: 0, annotationCount: 0), .tool(.crop))
        XCTAssertEqual(sidebarPanel(tool: .rectangle, selectionCount: 0, annotationCount: 0), .tool(.rectangle))
    }

    func test_redactionReview_overridesEverything() {
        // While proposals are under review, the review panel wins regardless of
        // tool or selection — the user is making redaction decisions.
        XCTAssertEqual(sidebarPanel(tool: .select, selectionCount: 0, annotationCount: 0,
                                    reviewingRedactions: true), .redactionReview)
        XCTAssertEqual(sidebarPanel(tool: .arrow, selectionCount: 1, annotationCount: 3,
                                    reviewingRedactions: true), .redactionReview)
        XCTAssertEqual(sidebarPanel(tool: .select, selectionCount: 2, annotationCount: 4,
                                    reviewingRedactions: true), .redactionReview)
    }
}
