import XCTest
import CoreGraphics
@testable import Sealshot

/// The auto-scroll decision automaton: step sizing and the
/// continue / finish / fallback transitions fed by stitcher verdicts plus
/// the stitcher's movement flag.
final class AutoScrollPolicyTests: XCTestCase {

    private let policy = AutoScrollPolicy()

    /// Most verdicts in these tests come from normal scrolling — movement.
    private func decide(_ result: ScrollStitcher.AppendResult,
                        moved: Bool = true,
                        _ state: inout AutoScrollPolicy.State) -> AutoScrollPolicy.Decision {
        policy.decide(after: result, moved: moved, state: &state)
    }

    // MARK: - Step sizing

    func testStepPoints_isFractionOfRegionHeight() {
        XCTAssertEqual(policy.stepPoints(forRegionHeight: 800), 480)   // 0.6×
    }

    func testStepPoints_clampsToMinimum() {
        XCTAssertEqual(policy.stepPoints(forRegionHeight: 50), 40)
    }

    func testStepPoints_clampsToMaximum() {
        XCTAssertEqual(policy.stepPoints(forRegionHeight: 3000), 800)
    }

    // MARK: - Finish: pixel-frozen bottom (short confirmation budget)

    func testDecide_duplicatesAfterProgress_finishAfterShortConfirmation() {
        var state = AutoScrollPolicy.State()
        XCTAssertEqual(decide(.appendedRows(300), &state), .continueScrolling)
        XCTAssertEqual(decide(.duplicate, moved: false, &state), .continueScrolling)
        XCTAssertEqual(decide(.duplicate, moved: false, &state), .continueScrolling)
        // Streak threshold reached — a frozen bottom still gets a short
        // grace period before the finish.
        for round in 1...policy.confirmationRounds {
            XCTAssertEqual(decide(.duplicate, moved: false, &state), .continueScrolling,
                           "confirmation round \(round), not finish")
        }
        XCTAssertEqual(decide(.duplicate, moved: false, &state), .finish,
                       "still frozen after the short budget = end of content")
    }

    // MARK: - Lazy loading: changing-but-not-scrolling gets the long budget

    func testDecide_inPlaceChangesAfterProgress_getLongLazyBudget() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        // A spinner / progressive images: frames change, page doesn't move.
        for _ in 0..<(policy.finishAfterDuplicates - 1 + policy.lazyConfirmationRounds) {
            XCTAssertEqual(decide(.appendedRows(0), moved: false, &state), .continueScrolling,
                           "changing pixels look like loading — keep waiting")
        }
        XCTAssertEqual(decide(.appendedRows(0), moved: false, &state), .finish,
                       "lazy budget exhausted with no new content")
    }

    func testDecide_lazyLoadArrivesDuringPatience_continuesScrolling() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        for _ in 0..<6 { _ = decide(.appendedRows(0), moved: false, &state) }   // waiting on a spinner
        XCTAssertEqual(decide(.appendedRows(140), &state), .continueScrolling,
                       "content landed — back to full-speed scrolling")
        XCTAssertEqual(policy.settleDelay(for: state), policy.settleDelay,
                       "normal cadence restored")
        XCTAssertEqual(decide(.appendedRows(0), moved: false, &state), .continueScrolling,
                       "patience budget restarted")
    }

    func testSettleDelay_doublesDuringConfirmation() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        XCTAssertEqual(policy.settleDelay(for: state), policy.settleDelay)
        for _ in 0..<4 { _ = decide(.duplicate, moved: false, &state) }
        XCTAssertEqual(policy.settleDelay(for: state),
                       policy.settleDelay * policy.confirmationSettleMultiplier,
                       "confirmation steps wait longer for content to land")
    }

    func testDecide_progressResetsDuplicateStreak() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        _ = decide(.duplicate, moved: false, &state)
        _ = decide(.duplicate, moved: false, &state)
        XCTAssertEqual(decide(.appendedRows(120), &state), .continueScrolling)
        XCTAssertEqual(decide(.duplicate, moved: false, &state), .continueScrolling,
                       "streak must restart after new progress")
    }

    func testDecide_movingInteriorRefreshResetsDuplicateStreak() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        _ = decide(.duplicate, moved: false, &state)
        _ = decide(.duplicate, moved: false, &state)
        XCTAssertEqual(decide(.appendedRows(0), moved: true, &state), .continueScrolling)
        XCTAssertEqual(decide(.duplicate, moved: false, &state), .continueScrolling,
                       "content moved (refresh) — not end of page")
    }

    // MARK: - Fallback: the window doesn't auto-scroll

    func testDecide_noMovementFromTheStart_fallsBackToManual() {
        var state = AutoScrollPolicy.State()
        XCTAssertEqual(decide(.duplicate, moved: false, &state), .continueScrolling)
        XCTAssertEqual(decide(.duplicate, moved: false, &state), .fallbackToManual,
                       "2 fruitless steps with nothing stitched = can't drive this window")
    }

    func testDecide_inPlaceChangesFromTheStart_countAsFruitless() {
        var state = AutoScrollPolicy.State()
        XCTAssertEqual(decide(.appendedRows(0), moved: false, &state), .continueScrolling)
        XCTAssertEqual(decide(.appendedRows(0), moved: false, &state), .fallbackToManual,
                       "animated-but-undrivable window must fall back, not wait out the lazy budget")
    }

    // MARK: - Stable-frame end-of-content fast finish

    /// Once content has been captured, a run of pixel-identical (stopped)
    /// frames finishes fast — without riding the 16-step stall ceiling.
    func testDecide_stableFramesAfterProgress_finishFast() {
        var state = AutoScrollPolicy.State()
        _ = policy.decide(after: .appendedRows(800), moved: true, framesStable: false, state: &state)
        for _ in 0..<(policy.finishAfterStableFrames - 1) {
            XCTAssertEqual(policy.decide(after: .noOverlap, moved: false, framesStable: true, state: &state),
                           .continueScrolling)
        }
        XCTAssertEqual(policy.decide(after: .noOverlap, moved: false, framesStable: true, state: &state),
                       .finish, "the page has stopped — finish without the long stall")
    }

    /// A single non-stable step (the page moved again) resets the streak.
    func testDecide_stableStreakResetsWhenFrameChanges() {
        var state = AutoScrollPolicy.State()
        _ = policy.decide(after: .appendedRows(800), moved: true, framesStable: false, state: &state)
        _ = policy.decide(after: .noOverlap, moved: false, framesStable: true, state: &state)
        _ = policy.decide(after: .noOverlap, moved: false, framesStable: true, state: &state)
        _ = policy.decide(after: .appendedRows(800), moved: true, framesStable: false, state: &state)  // moved → reset
        XCTAssertEqual(policy.decide(after: .noOverlap, moved: false, framesStable: true, state: &state),
                       .continueScrolling, "streak restarts after movement")
    }

    /// Stable frames BEFORE any content stitched mean the window can't be
    /// driven — that path falls back to manual, it must not "finish" empty.
    func testDecide_stableFramesBeforeAnyProgress_doNotFinish() {
        var state = AutoScrollPolicy.State()
        for _ in 0..<(policy.finishAfterStableFrames + 2) {
            let d = policy.decide(after: .duplicate, moved: false, framesStable: true, state: &state)
            XCTAssertNotEqual(d, .finish, "must not finish with nothing captured")
        }
    }

    // MARK: - Re-seed: an unmatchable seed (page-top header/hero transforms)

    /// Before any successful stitch, a no-overlap means the SEED was a poor
    /// anchor — captured at a page top whose header/hero transforms on the
    /// first scroll, sharing no overlap with the body. The policy re-anchors
    /// on the current frame rather than drift further from a seed it can't
    /// match (a duplicate, by contrast, means the window never moved → fall
    /// back).
    func testDecide_noOverlapFromTheStart_reseedsAnchor() {
        var state = AutoScrollPolicy.State()
        XCTAssertEqual(decide(.noOverlap, moved: false, &state), .reseedAnchor)
    }

    /// Re-seeding is bounded: a region that NEVER aligns (a video player whose
    /// frames always change) exhausts the budget and falls back.
    func testDecide_noOverlapForever_reseedsThenFallsBack() {
        var state = AutoScrollPolicy.State()
        for round in 1...policy.maxReseeds {
            XCTAssertEqual(decide(.noOverlap, moved: false, &state), .reseedAnchor,
                           "reseed \(round) of \(policy.maxReseeds)")
        }
        XCTAssertEqual(decide(.noOverlap, moved: false, &state), .fallbackToManual,
                       "an unstitchable changing region falls back after the reseed budget")
    }

    /// The realistic case: the seed can't match, but the first frame after
    /// re-anchoring aligns — the session recovers and proceeds. A later miss
    /// (after real progress) is a transient stall, never another re-seed.
    func testDecide_reseedThenAlign_proceeds() {
        var state = AutoScrollPolicy.State()
        XCTAssertEqual(decide(.noOverlap, moved: false, &state), .reseedAnchor)
        XCTAssertEqual(decide(.appendedRows(300), &state), .continueScrolling)
        XCTAssertEqual(decide(.noOverlap, moved: false, &state), .continueScrolling)
    }

    func testDecide_noOverlapAfterProgress_keepsGoing() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        XCTAssertEqual(decide(.noOverlap, moved: false, &state), .continueScrolling)
        XCTAssertEqual(decide(.noOverlap, moved: false, &state), .continueScrolling,
                       "transient misses after progress never abandon the session")
    }

    // MARK: - Caps

    func testDecide_capReached_finishes() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        XCTAssertEqual(decide(.capReached, &state), .finish)
    }

    // MARK: - Stall ceiling: zero growth must eventually finish

    func testDecide_noGrowthForManySteps_finishesWithWhatWasCaptured() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        // Alternating moving interior refreshes and unstitchable frames —
        // verdicts that never trip the end-of-content paths but add nothing.
        var decisions: [AutoScrollPolicy.Decision] = []
        for i in 0..<policy.finishAfterStalledSteps {
            decisions.append(i.isMultiple(of: 2)
                ? decide(.appendedRows(0), moved: true, &state)
                : decide(.noOverlap, moved: false, &state))
        }
        XCTAssertTrue(decisions.dropLast().allSatisfy { $0 == .continueScrolling })
        XCTAssertEqual(decisions.last, .finish,
                       "sustained zero growth must deliver the capture, not loop forever")
    }

    func testDecide_extensionResetsStallCounter() {
        var state = AutoScrollPolicy.State()
        _ = decide(.appendedRows(300), &state)
        for _ in 0..<(policy.finishAfterStalledSteps - 1) {
            XCTAssertEqual(decide(.appendedRows(0), moved: true, &state), .continueScrolling)
        }
        _ = decide(.appendedRows(50), &state)   // grew — reset
        XCTAssertEqual(decide(.appendedRows(0), moved: true, &state), .continueScrolling,
                       "stall counter must restart after growth")
    }

    func testStallCeiling_exceedsLazyBudget() {
        // The lazy patience path must finish via its own budget, not get
        // cut short by the backstop.
        XCTAssertGreaterThan(policy.finishAfterStalledSteps,
                             policy.finishAfterDuplicates + policy.lazyConfirmationRounds)
    }

    // MARK: - Settle params

    func testSettleParams_haveSaneDefaults() {
        let p = AutoScrollPolicy()
        XCTAssertEqual(p.settleDelay, 0.25, "floor wait raised toward the ~0.3s browser scroll")
        XCTAssertGreaterThan(p.settleMaxWait, p.settleDelay)
        XCTAssertGreaterThan(p.settlePollInterval, 0)
        XCTAssertLessThan(p.settlePollInterval, p.settleMaxWait)
        XCTAssertGreaterThan(p.settleStableThreshold, 0)
    }

    // MARK: - Micro-step variant

    func testMicroStep_isTunedConsistently() {
        let p = AutoScrollPolicy.microStep
        // Small (~100pt) steps with large overlap; single grab per step.
        XCTAssertLessThanOrEqual(p.stepPoints(forRegionHeight: 750), 140)
        XCTAssertGreaterThanOrEqual(p.stepPoints(forRegionHeight: 750), 60)
        XCTAssertTrue(p.usesSettleStability,
                      "settled sampling required — mid-glide frames poison the stitch anchor")
        // Streak budgets scale with the higher step rate, and the stall
        // ceiling still exceeds the longest confirmation path.
        XCTAssertGreaterThan(p.finishAfterStalledSteps,
                             p.finishAfterDuplicates + p.lazyConfirmationRounds)
        XCTAssertGreaterThan(p.finishAfterDuplicates, AutoScrollPolicy().finishAfterDuplicates)
        // Generous settle budget: smooth-scroll pages glide ~0.5s per step.
        XCTAssertGreaterThanOrEqual(p.settleMaxWait, AutoScrollPolicy().settleMaxWait)
    }

    func testCurrentPolicy_microByDefault_classicViaFlag() {
        let suite = "AutoScrollPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertLessThanOrEqual(
            AutoScrollPolicy.current(defaults: defaults).stepFraction, 0.2,
            "no flag -> micro-step prototype")
        defaults.set(false, forKey: "ScrollMicroStep")
        XCTAssertEqual(AutoScrollPolicy.current(defaults: defaults).stepFraction, 0.6,
                       "flag false -> classic big strides")
        defaults.set(true, forKey: "ScrollMicroStep")
        XCTAssertLessThanOrEqual(
            AutoScrollPolicy.current(defaults: defaults).stepFraction, 0.2)
    }
}
