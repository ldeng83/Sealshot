import CoreGraphics
import Foundation

/// Decision automaton for auto-scroll capture: how far each synthetic step
/// scrolls, and when to keep going, finish, or hand the session back to
/// manual scrolling. Pure — the driver loop feeds it stitcher verdicts.
struct AutoScrollPolicy {

    enum Decision: Equatable {
        case continueScrolling
        case finish
        case fallbackToManual
        /// Drop the current (unmatchable) anchor and re-seed the stitcher on
        /// the just-sampled frame. Emitted only before the first real stitch,
        /// when a no-overlap means the SEED itself was a poor anchor.
        case reseedAnchor
    }

    /// Carried by the driver across steps.
    struct State {
        var extendedOnce = false
        var duplicateStreak = 0
        var fruitlessSteps = 0
        /// Slow extra steps taken after the duplicate streak filled, giving
        /// lazy-loading pages time to produce more content before we finish.
        var confirmationRoundsUsed = 0
        var isConfirming = false
        /// Consecutive steps that added no stitched rows (any verdict).
        /// Backstop for stalls the duplicate path can't see — e.g. a video
        /// player whose frames never stitch (noOverlap forever).
        var stalledSteps = 0
        /// Anchor re-seeds spent before the first real stitch (see
        /// `maxReseeds`). Reset once content actually stitches.
        var reseedsUsed = 0
        /// Consecutive steps whose grabbed frame was pixel-identical to the
        /// previous step's — the page has stopped moving. A definitive
        /// end-of-content signal that short-circuits the much longer stall
        /// ceiling (which exists for content that keeps CHANGING without
        /// stitching, e.g. a video region).
        var stableFrameStreak = 0
    }

    /// Fraction of the region height each step scrolls — small enough to
    /// guarantee stitching overlap (40% here, against the stitcher's
    /// ~96-row evidence floor), big enough to cover pages fast.
    var stepFraction: CGFloat = 0.6
    var minStepPoints: CGFloat = 40
    var maxStepPoints: CGFloat = 800
    /// Wait after each synthetic step before sampling. Sampling mid-scroll-
    /// animation stitches correctly (the stitcher aligns frames at any
    /// offset, like manual mode), but browsers animate wheel scrolls over
    /// ~300 ms — too far below that and consecutive samples drift apart
    /// enough to lose overlap and lean on re-anchoring.
    var settleDelay: TimeInterval = 0.25
    /// Re-grab interval while waiting for the scroll animation to settle.
    var settlePollInterval: TimeInterval = 0.06
    /// Hard cap on settle waiting per step — then sample regardless (never stalls).
    var settleMaxWait: TimeInterval = 0.6
    /// Mean-abs-difference threshold two consecutive grabs must be within to be
    /// considered settled (passed to `FrameSettle.isStable`).
    var settleStableThreshold: Double = 3.0
    /// Whether each step double-grabs until stable (classic big strides ride
    /// browser smooth-scroll animations; small commanded steps don't, so the
    /// micro policy samples once per step).
    var usesSettleStability = true
    /// PURE fixed-step stitching: append the commanded advance blindly with
    /// no alignment search or verification. Only page-stopped detection and
    /// the final partial-step alignment remain. Trade-off (accepted): a page
    /// that moves differently than commanded mid-run produces a seam that
    /// nothing detects.
    var blindStitching = false
    /// Consecutive duplicates (after progress) that mean end-of-content.
    var finishAfterDuplicates = 3
    /// Steps with no stitched progress at session start before concluding
    /// the window can't be driven (non-native scrollers).
    var fallbackAfterFruitlessSteps = 2
    /// No-overlap steps before the first real stitch that re-seed the anchor
    /// on the current frame instead of falling back. The seed is captured at
    /// the page top, whose header/hero often transforms on the first scroll
    /// and shares no overlap with the body — so the seed, not the window, is
    /// the bad anchor. The page body aligns frame-to-frame, so one re-seed
    /// almost always recovers; the budget bounds a region that truly never
    /// stitches (a video player) so it still falls back.
    var maxReseeds = 3
    /// Slow extra steps after the duplicate streak fills, before finishing —
    /// for a PIXEL-FROZEN page bottom, end-of-content is near-certain, so
    /// only a short grace period.
    var confirmationRounds = 2
    /// The patience budget when the page bottom is CHANGING without
    /// scrolling (in-place re-anchors): that's what a lazy-load spinner or
    /// progressive images look like, so wait much longer for the content
    /// to land before concluding end-of-content.
    var lazyConfirmationRounds = 8
    /// Settle-delay multiplier during confirmation steps.
    var confirmationSettleMultiplier: Double = 2.0
    /// Consecutive zero-growth steps (any verdict) before finishing with
    /// what was captured — the backstop above the confirmation budgets
    /// (3 + 8 lazy rounds = 11 must fit under it), and for stalls the
    /// duplicate path can't see (noOverlap forever on a video region).
    var finishAfterStalledSteps = 16
    /// Consecutive pixel-identical (stopped) frames, once content has been
    /// captured, that end the session — a much faster end-of-content exit than
    /// `finishAfterStalledSteps` when the page has genuinely stopped (vs a
    /// region that keeps changing without stitching).
    var finishAfterStableFrames = 3

    // MARK: - Micro-step variant (Shottr-style)

    /// Small fast steps instead of big strides (Shottr-style, ~100pt). Most
    /// of the viewport overlaps between consecutive frames, the commanded
    /// step feeds the stitcher's CONSTRAINED search (`expectedShift`) so
    /// wrong-offset matches are impossible, small wheel deltas don't trigger
    /// smooth-scroll animations (single grab per step, no settle stability
    /// loop), and the first-step no-overlap → reseed path — which silently
    /// DROPS the page top — essentially can't occur. Streak budgets scale
    /// with the higher step rate.
    static var microStep: AutoScrollPolicy {
        var p = AutoScrollPolicy()
        p.stepFraction = 0.13          // ~100pt on a typical 750pt viewport
        p.minStepPoints = 60
        p.maxStepPoints = 140
        p.settleDelay = 0.03
        p.settlePollInterval = 0.03
        // Per-step settle-stability sampling, like Shottr (video-measured:
        // it glides ~3 frames then samples exactly one motionless frame).
        // Smooth-scrolling pages (YouTube) animate each wheel step over
        // ~0.5s — sampling mid-glide poisons the stitch anchor with
        // fractional-offset frames that a settled page can never re-match.
        // On non-animating pages stability confirms on the first poll
        // (~30ms), so the cost is adaptive.
        p.settleMaxWait = 0.8
        p.usesSettleStability = true
        p.blindStitching = true
        p.finishAfterDuplicates = 6
        p.confirmationRounds = 4
        p.lazyConfirmationRounds = 12
        // Patience for scroll-PINNED sections (in-place animations that eat
        // steps of scroll budget while frames idle): the true page bottom
        // still exits fast via the duplicate path (frame == reference).
        p.finishAfterStableFrames = 24
        p.fallbackAfterFruitlessSteps = 6
        p.finishAfterStalledSteps = 60  // > duplicates + lazy rounds, and steps are cheap
        return p
    }

    /// The active policy. Micro-step is the default (prototype); A/B the
    /// classic big-stride policy via
    /// `defaults write com.seal-shot.sealshot.direct ScrollMicroStep -bool false`.
    static func current(defaults: UserDefaults = .standard) -> AutoScrollPolicy {
        if defaults.object(forKey: "ScrollMicroStep") != nil,
           !defaults.bool(forKey: "ScrollMicroStep") {
            return AutoScrollPolicy()
        }
        return .microStep
    }

    func stepPoints(forRegionHeight h: CGFloat) -> CGFloat {
        min(max(h * stepFraction, minStepPoints), maxStepPoints)
    }

    /// The wait after a step before sampling — longer while confirming
    /// end-of-content so lazy loads have time to land.
    func settleDelay(for state: State) -> TimeInterval {
        state.isConfirming ? settleDelay * confirmationSettleMultiplier : settleDelay
    }

    /// `moved` is the stitcher's `lastAppendMoved`: whether the frame sat at
    /// a different scroll position than the one before it. It splits the
    /// no-growth verdicts into three distinct situations:
    ///  • duplicate (pixel-frozen)        → end-of-content, short grace;
    ///  • in place but pixels changing    → looks like lazy loading — wait
    ///    out the long patience budget before giving up;
    ///  • moved without growing           → re-scrolling captured territory,
    ///    bounded progress under the stall ceiling.
    func decide(after result: ScrollStitcher.AppendResult, moved: Bool,
                framesStable: Bool = false, state: inout State) -> Decision {
        // Definitive end-of-content: once we've captured something, consecutive
        // pixel-identical (stopped) frames finish fast — no need to ride the
        // long stall ceiling, which is reserved for content that keeps changing
        // without stitching (a video region).
        if framesStable && state.extendedOnce {
            state.stableFrameStreak += 1
            if state.stableFrameStreak >= finishAfterStableFrames { return .finish }
        } else {
            state.stableFrameStreak = 0
        }
        switch result {
        case .appendedRows(let delta) where delta > 0:
            state.extendedOnce = true
            state.duplicateStreak = 0
            state.fruitlessSteps = 0
            state.confirmationRoundsUsed = 0
            state.isConfirming = false
            state.stalledSteps = 0
            state.reseedsUsed = 0
            return .continueScrolling
        case .appendedRows where moved:
            // Moving without growing is bounded progress (toward the
            // frontier) — count it against the stall ceiling.
            state.extendedOnce = true
            state.duplicateStreak = 0
            state.fruitlessSteps = 0
            state.confirmationRoundsUsed = 0
            state.isConfirming = false
            state.stalledSteps += 1
            return state.stalledSteps >= finishAfterStalledSteps ? .finish : .continueScrolling
        case .appendedRows:
            // In place with changing pixels — lazy-load suspect.
            guard state.extendedOnce else { return fruitlessStep(state: &state) }
            return endOfContentStep(state: &state, roundsBudget: lazyConfirmationRounds)
        case .duplicate:
            guard state.extendedOnce else { return fruitlessStep(state: &state) }
            return endOfContentStep(state: &state, roundsBudget: confirmationRounds)
        case .noOverlap:
            guard state.extendedOnce else {
                // No stitch yet AND the content changed to something the seed
                // can't match: the SEED is the bad anchor (a page top whose
                // header/hero transforms on the first scroll). Re-seed on this
                // frame — the body aligns frame-to-frame from here — bounded so
                // a region that never stitches still falls back. (A non-moving
                // window yields duplicates, not no-overlap, so this never
                // masks an undrivable scroller.)
                guard state.reseedsUsed < maxReseeds else { return .fallbackToManual }
                state.reseedsUsed += 1
                return .reseedAnchor
            }
            // Transient miss mid-session; deterministic steps make this rare
            // and the canvas re-anchor usually recovers on the next sample.
            // The stall ceiling stops a permanent miss (an unstitchable
            // region, e.g. a video player) from looping forever.
            state.stalledSteps += 1
            return state.stalledSteps >= finishAfterStalledSteps ? .finish : .continueScrolling
        case .capReached:
            return .finish
        }
    }

    /// No stitched progress before the first real movement: the window
    /// likely can't be driven at all.
    private func fruitlessStep(state: inout State) -> Decision {
        state.fruitlessSteps += 1
        return state.fruitlessSteps >= fallbackAfterFruitlessSteps
            ? .fallbackToManual : .continueScrolling
    }

    /// Shared streak + confirmation machinery; the budget is what differs
    /// between a frozen bottom (short) and a changing one (long).
    private func endOfContentStep(state: inout State, roundsBudget: Int) -> Decision {
        state.stalledSteps += 1
        state.duplicateStreak += 1
        guard state.duplicateStreak >= finishAfterDuplicates else {
            return .continueScrolling
        }
        if state.confirmationRoundsUsed < roundsBudget {
            state.confirmationRoundsUsed += 1
            state.isConfirming = true
            return .continueScrolling
        }
        return .finish
    }
}