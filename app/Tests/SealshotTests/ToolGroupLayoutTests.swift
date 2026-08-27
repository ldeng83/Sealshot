import XCTest
@testable import Sealshot

/// Covers the grouped-tool model: the `ToolGroup` definitions and the toolbar
/// slot layout. Rectangle+Ellipse collapse into one pill; Line and Arrow each
/// stand alone as their own toolbar icon.
final class ToolGroupLayoutTests: XCTestCase {

    private let shape = EditorToolbarBuilder.shapeGroup

    func testShapeGroup_membersAndDefault() {
        XCTAssertEqual(shape.tools, [.rectangle, .ellipse])
        XCTAssertEqual(shape.defaultTool, .rectangle)
    }

    /// Arrow joined the "arrow" chevron group when Free Arrow shipped
    /// (Line Arrow / Free Arrow); Line remains a standalone pill.
    func testLineStandsAlone_arrowJoinsArrowGroup() {
        XCTAssertEqual(EditorToolbarBuilder.group(containing: .arrow)?.id, "arrow")
        XCTAssertNil(EditorToolbarBuilder.group(containing: .line))
    }

    func testGroupContaining_resolvesOnlyShapeMembers() {
        XCTAssertEqual(EditorToolbarBuilder.group(containing: .rectangle)?.id, "shape")
        XCTAssertEqual(EditorToolbarBuilder.group(containing: .ellipse)?.id, "shape")
        XCTAssertNil(EditorToolbarBuilder.group(containing: .select))
        XCTAssertNil(EditorToolbarBuilder.group(containing: .pen))
    }

    func testLineAndArrowAreSeparateAdjacentSlots_lineBeforeArrow() {
        let line = EditorToolbarBuilder.slotIndex(for: .line)
        let arrow = EditorToolbarBuilder.slotIndex(for: .arrow)
        XCTAssertNotNil(line); XCTAssertNotNil(arrow)
        XCTAssertNotEqual(line, arrow)            // no longer share a slot
        XCTAssertEqual(line! + 1, arrow!)         // Line immediately precedes Arrow
    }

    func testShapePair_stillSharesOneSlot() {
        XCTAssertEqual(
            EditorToolbarBuilder.slotIndex(for: .rectangle),
            EditorToolbarBuilder.slotIndex(for: .ellipse)
        )
    }

    func testEveryToolResolvesToASlot() {
        for tool in EditorTool.allCases {
            XCTAssertNotNil(
                EditorToolbarBuilder.slotIndex(for: tool),
                "no toolbar slot for \(tool)"
            )
        }
    }

    func testSelectIsFirstAndLiveTextIsLast() {
        XCTAssertEqual(EditorToolbarBuilder.slotIndex(for: .select), 0)
        let last = EditorToolbarBuilder.toolLayout.count - 1
        XCTAssertEqual(EditorToolbarBuilder.slotIndex(for: .textSelect), last)
    }

    func testLayoutCollapsesOnlyShapePair_intoElevenSlots() {
        // 12 tools (incl. hand + blur) − 1 merged pair (shapes saves one slot) = 11 slots.
        // Line and Arrow each occupy their own slot.
        XCTAssertEqual(EditorToolbarBuilder.toolLayout.count, 11)
    }
}
