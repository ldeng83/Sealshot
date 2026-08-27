import XCTest
@testable import Sealshot

/// The 3-bullet bound exists because the on-device model ignores length
/// instructions on dense screenshots and returns runaway lists. A Live Capture
/// scene needs one bullet per window, and its bullet count is bounded by the
/// window count — data, not a guess — so scenes pass their own bounds.
final class SummaryClampSceneTests: XCTestCase {

    func test_default_stillThreeBullets() {
        let raw = """
        Overview sentence.
        - one
        - two
        - three
        - four
        """
        let clamped = SummaryClamp.clamp(raw)
        XCTAssertNotNil(clamped)
        XCTAssertFalse(clamped!.contains("four"),
                       "non-scene callers must keep today's 3-bullet bound")
    }

    func test_sceneBoundsAllowOneBulletPerWindow() {
        let raw = """
        - Safari — Start: a news article.
        - Terminal — zsh: a test run.
        - Notes — Prep: an agenda.
        - Mail — Inbox: two unread messages.
        - Music — Library: an album view.
        """
        let clamped = SummaryClamp.clamp(raw, maxBullets: 5, maxBulletChars: 120,
                                         maxTotalChars: 5 * 120)
        XCTAssertNotNil(clamped)
        XCTAssertTrue(clamped!.contains("Music — Library"),
                      "the fifth window's bullet must survive (got: \(clamped!))")
    }

    /// The boundary the test above is far too short to reach: every bullet at
    /// EXACTLY the per-bullet budget. `clamp` re-adds the "- " prefix after the
    /// per-bullet clamp and then enforces the total against the string it
    /// composed, so a budget of n × perBullet is short by the prefixes and
    /// newlines and deletes whole trailing bullets — the backmost windows'.
    /// A scene bullet reads "App — Long Window Title: <~16 words>", so hitting
    /// the budget is ordinary, not a corner case.
    func test_sceneBounds_allBulletsAtFullBudget_allSurvive() {
        let per = SummaryClamp.sceneMaxBulletChars
        for n in 1...6 {
            let bullets = (0..<n).map { i -> String in
                let marker = "W\(i)"
                let filler = String(repeating: "x", count: per - marker.count - 1)
                return "\(marker) \(filler)"          // exactly `per` characters
            }
            XCTAssertEqual(bullets.map(\.count), Array(repeating: per, count: n))
            let raw = bullets.map { "- \($0)" }.joined(separator: "\n")

            let clamped = SummaryClamp.clamp(
                raw, maxBullets: n, maxBulletChars: per,
                maxTotalChars: SummaryClamp.totalBudget(bullets: n, perBullet: per))

            XCTAssertNotNil(clamped)
            XCTAssertEqual(clamped?.components(separatedBy: "\n").count, n,
                           "n=\(n): every window must keep its bullet")
            for i in 0..<n {
                XCTAssertTrue(clamped!.contains("W\(i) "),
                              "n=\(n): window \(i)'s bullet was dropped or truncated")
            }
            XCTAssertFalse(clamped!.contains("…"),
                           "n=\(n): a bullet already within budget must not be ellipsized")
        }
    }
}
