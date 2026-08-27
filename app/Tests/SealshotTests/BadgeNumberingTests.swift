import XCTest
@testable import Sealshot

final class BadgeNumberingTests: XCTestCase {
    private func badge() -> Annotation {
        Annotation(geometry: .badge(center: .zero, radius: 16),
                   style: Style(strokeColor: SerializableColor(r: 1, g: 1, b: 1, a: 1), strokeWidth: 0,
                                fillColor: SerializableColor(r: 1, g: 0, b: 0, a: 1)))
    }
    private func rect() -> Annotation {
        Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 5, height: 5)),
                   style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 2))
    }

    func test_numbersInOrderAmongBadgesOnly() {
        let b1 = badge(), r = rect(), b2 = badge(), b3 = badge()
        let list = [b1, r, b2, b3]
        XCTAssertEqual(badgeNumber(for: b1.id, in: list), 1)
        XCTAssertEqual(badgeNumber(for: b2.id, in: list), 2)
        XCTAssertEqual(badgeNumber(for: b3.id, in: list), 3)
        XCTAssertNil(badgeNumber(for: r.id, in: list))
    }

    func test_renumbersAfterDeletingMiddleBadge() {
        let b1 = badge(), b3 = badge()
        let afterDelete = [b1, b3]
        XCTAssertEqual(badgeNumber(for: b1.id, in: afterDelete), 1)
        XCTAssertEqual(badgeNumber(for: b3.id, in: afterDelete), 2)
    }
}
