import XCTest
@testable import Sealshot

/// `librarySelectionRange` is the shift-click range selection for the Library,
/// mirroring the editor strip: the inclusive span from the anchor to the
/// clicked item in display order. Falls back to just the target when there's no
/// usable anchor.
final class LibraryRangeSelectionTests: XCTestCase {

    private func u(_ n: String) -> URL { URL(fileURLWithPath: "/lib/\(n)") }

    func test_anchorBeforeTarget_selectsInclusiveSpan() {
        let order = [u("a"), u("b"), u("c"), u("d")]
        XCTAssertEqual(
            librarySelectionRange(from: u("a"), to: u("c"), in: order),
            Set([u("a"), u("b"), u("c")]))
    }

    func test_anchorAfterTarget_selectsInclusiveSpan() {
        let order = [u("a"), u("b"), u("c"), u("d")]
        XCTAssertEqual(
            librarySelectionRange(from: u("c"), to: u("a"), in: order),
            Set([u("a"), u("b"), u("c")]))
    }

    func test_anchorEqualsTarget_selectsOnlyTarget() {
        let order = [u("a"), u("b"), u("c")]
        XCTAssertEqual(
            librarySelectionRange(from: u("b"), to: u("b"), in: order),
            Set([u("b")]))
    }

    func test_noAnchor_selectsOnlyTarget() {
        let order = [u("a"), u("b"), u("c")]
        XCTAssertEqual(
            librarySelectionRange(from: nil, to: u("b"), in: order),
            Set([u("b")]))
    }

    func test_anchorNotInOrder_selectsOnlyTarget() {
        let order = [u("a"), u("b"), u("c")]
        XCTAssertEqual(
            librarySelectionRange(from: u("gone"), to: u("b"), in: order),
            Set([u("b")]))
    }

    // MARK: libraryExtendedSelection (⇧-click after a marquee / ⌘-click set)

    func test_extended_unionsRangeWithFloor() {
        // Marquee left {a,b}, then ⇧-click e → range c..e stays additive over it.
        let order = [u("a"), u("b"), u("c"), u("d"), u("e")]
        XCTAssertEqual(
            libraryExtendedSelection(from: u("c"), to: u("e"), in: order,
                                     floor: [u("a"), u("b")]),
            Set([u("a"), u("b"), u("c"), u("d"), u("e")]))
    }

    func test_extended_noAnchorStillKeepsFloorPlusTarget() {
        // Anchor lost (e.g. ⌘-clicked it away): ⇧-click adds the target to the
        // floor rather than collapsing to just the target.
        let order = [u("a"), u("b"), u("c")]
        XCTAssertEqual(
            libraryExtendedSelection(from: nil, to: u("c"), in: order,
                                     floor: [u("a")]),
            Set([u("a"), u("c")]))
    }

    func test_extended_emptyFloorMatchesPlainRange() {
        // With nothing to preserve it behaves exactly like a bare range.
        let order = [u("a"), u("b"), u("c"), u("d")]
        XCTAssertEqual(
            libraryExtendedSelection(from: u("a"), to: u("c"), in: order, floor: []),
            librarySelectionRange(from: u("a"), to: u("c"), in: order))
    }

    func test_extended_successiveShrinkKeepsFloorFixed() {
        // Floor {a,b}, anchor a: ⇧-click d → a..d ∪ floor, then ⇧-click c
        // shrinks the range but the floor still holds.
        let order = [u("a"), u("b"), u("c"), u("d"), u("e")]
        let floor: Set<URL> = [u("a"), u("b")]
        XCTAssertEqual(
            libraryExtendedSelection(from: u("a"), to: u("d"), in: order, floor: floor),
            Set([u("a"), u("b"), u("c"), u("d")]))
        XCTAssertEqual(
            libraryExtendedSelection(from: u("a"), to: u("c"), in: order, floor: floor),
            Set([u("a"), u("b"), u("c")]))
    }
}
