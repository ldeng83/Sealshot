import XCTest
@testable import Sealshot

/// The ancestor walk must reach AXWebArea even when the cursor is over deeply
/// nested web content — the real bug was a 16-level cap that truncated before
/// AXWebArea on typical pages, so browsers highlighted the whole window instead
/// of the page body. `climb` is the pure walk extracted for testing.
final class AXElementProbeClimbTests: XCTestCase {

    /// A synthetic AX tree as a flat role list, innermost (index 0) → outermost.
    /// Parent of node i is node i+1; the boundary is the window/application.
    private func climb(roles: [String], maxDepth: Int) -> [AXElementProbe.ChainEntry] {
        AXElementProbe.climb(
            from: 0,
            maxDepth: maxDepth,
            role: { roles[$0] },
            frame: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            parent: { $0 + 1 < roles.count ? $0 + 1 : nil },
            isBoundary: { roles[$0] == "AXWindow" || roles[$0] == "AXApplication" }
        )
    }

    func testReachesAXWebAreaBeyondOldCap() {
        // AXWebArea sits 25 groups above the hit element — beyond the old 16 cap.
        let roles = Array(repeating: "AXGroup", count: 25)
            + ["AXWebArea", "AXScrollArea", "AXWindow"]
        let chain = climb(roles: roles, maxDepth: 60)
        XCTAssertTrue(chain.contains { $0.role == "AXWebArea" },
                      "deep AXWebArea must be reached, not truncated")
    }

    func testStopsAtAXWebArea() {
        // Once AXWebArea is found nothing above it matters — the walk stops there
        // so cost stays bounded on heavy pages.
        let roles = ["AXGroup", "AXGroup", "AXWebArea", "AXScrollArea", "AXWindow"]
        let chain = climb(roles: roles, maxDepth: 60)
        XCTAssertEqual(chain.map(\.role), ["AXGroup", "AXGroup", "AXWebArea"])
    }

    func testStopsAtBoundaryParent() {
        // Native app: the walk ends when the parent is the window (no AXWebArea).
        let roles = ["AXButton", "AXGroup", "AXWindow"]
        let chain = climb(roles: roles, maxDepth: 60)
        XCTAssertEqual(chain.map(\.role), ["AXButton", "AXGroup"])
    }

    func testRespectsMaxDepthOnPathologicalTree() {
        // No AXWebArea, no boundary within reach → capped at maxDepth.
        let roles = Array(repeating: "AXGroup", count: 200)
        let chain = climb(roles: roles, maxDepth: 60)
        XCTAssertEqual(chain.count, 60)
    }
}
