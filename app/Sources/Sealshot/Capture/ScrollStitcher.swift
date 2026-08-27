import CoreGraphics
import Foundation

/// Incremental stitching engine for scrolling capture. Frames (same-size
/// viewport grabs, sampled while the user scrolls) are appended one at a
/// time; overlap is found by row-signature alignment scored on INFORMATIVE
/// rows (content edges), so whitespace-dominant pages (chat logs) can't
/// false-lock a tiny offset on blank-to-blank matches.
///
/// Stitching is BIDIRECTIONAL: scrolling down extends the canvas at the
/// bottom, scrolling up prepends at the top (start mid-page, capture above
/// the starting point). Down is the primary direction — it's searched first.
///
/// Composition is a live canvas: each aligned frame redraws its whole
/// scrolled region, not just the new rows. The refresh overwrites the
/// previous frame's pixels in the overlap, which heals floating mid-viewport
/// chrome (Jump-to-bottom pills): every stamp is erased by the next frame's
/// clean content, so the overlay survives exactly once. Fixed top chrome
/// lands once from the first frame; fixed bottom chrome is only drawn by
/// frames at the canvas frontier, so wandering back down through captured
/// territory never stamps a footer mid-content.
///
/// Pure CoreGraphics — no AppKit/SCK — so the whole engine is unit-tested
/// against synthetic pages. Memory is the canvas (stitched height × width,
/// grown geometrically, content bounded by `maxHeight`).
final class ScrollStitcher {

    struct Params {
        /// Smallest acceptable overlap between consecutive frames, in rows.
        /// Doubles as the evidence floor: an alignment judged on fewer rows
        /// than this is rejected outright. Near-viewport shifts leave only a
        /// sliver of overlap, and repeated page content (chat banners,
        /// identical bubbles) can match a sliver perfectly at a wrong shift
        /// — real-world false accepts were observed on ~50-row windows while
        /// true alignments had 400+.
        var minOverlapRows = 96
        /// Fraction of scored rows that must match to accept an alignment.
        /// Kept deliberately below the `minExactMatchFraction` guard's reach:
        /// photographic / lazy-loading pages (image masonry like Unsplash)
        /// re-render part of the overlap between consecutive frames — newly
        /// streamed-in images, photo resampling — so the CORRECT, sharply-
        /// unique shift matches only ~2/3 of rows (0.679 measured on a real
        /// failing first step). The false-lock defenses are `minOverlapRows`,
        /// informative-row scoring, and `minExactMatchFraction` (exact matches
        /// are a subset of these, so an accepted shift still needs ≥50% pixel-
        /// perfect rows) — NOT this ratio; on real captures genuine shifts
        /// scored ≥0.66 while every wrong shift scored ≤0.09, a wide gap.
        var matchRatio = 0.6
        /// Same-index match fraction at/above which a frame is a duplicate.
        var duplicateRatio = 0.98
        /// Stitched-height ceiling in pixels; appends past it are refused.
        var maxHeight = 30_000
        /// Largest pixel gap between samples — drives how many columns are
        /// sampled per row (`width / pixelsPerSample`), so wide frames get more.
        var pixelsPerSample = 32
        /// Sample-count floor: every frame samples at least this many columns,
        /// so narrow frames keep the well-tested 16-sample behavior.
        var minSamples = 16
        /// Sample-count ceiling — the `SIMD64` lane count.
        var maxSamples = 64
        /// Fraction of sampled columns allowed to disagree in a row that still
        /// counts as matching (3/16 — identical to the legacy 3-of-16 at the
        /// 16-sample floor). Tolerates narrow viewport-fixed churn.
        var maxChurnFraction = 3.0 / 16.0
        /// Per-column grayscale delta treated as agreement when SCORING an
        /// alignment (the match/exact counts in `alignmentScore` and re-anchor
        /// verification). Browsers re-rasterize content at a new antialiasing
        /// phase after a scroll even when the layout translates by an exact
        /// integer offset, so byte-exact scoring refuses genuine alignments.
        /// Measured on real failing captures (Chrome):
        ///  • PingIdentity admin modal — 91% of pixels byte-identical at the
        ///    true shift, the rest ≤Δ31 glyph-edge dither; byte-exact scored
        ///    it match=0.65/exact=0.08 (all guards refused, session died).
        ///  • Gmail inbox — heavier re-render: 78% byte-identical with a
        ///    Δ9–24 tail; at tolerance 8 the true shift still only scored
        ///    match=0.72 and was refused.
        /// At Δ≤8 the Ping true shift scored 0.98/0.76 while every wrong
        /// shift stayed ≤0.67/≤0.17 — a wide margin. 8 is deliberately NOT
        /// raised toward `fixedColumnTolerance` (24): at 24, near-white
        /// content on white (light chat bubbles, pale UI text) falls inside
        /// the tolerance and a whitespace-heavy page false-locks (caught by
        /// the narrow-bubble test). Gmail's heavier Δ9–24 tail is handled by
        /// the constrained-mode moderate-match unique-peak accept
        /// (`constrainedMatchFloor`) instead of more tolerance. Vote
        /// indexing and duplicate/page-stopped detection stay byte-exact:
        /// consecutive SCK grabs of static content are byte-identical, and
        /// the vote index only needs the noise-free minority of rows to
        /// surface candidates. The tolerance is ANCHORED: it applies only to
        /// rows with at least one byte-exact sampled column (see
        /// `RowSig.churnColumns(vs:mask:tolerance:)`), so smooth gradients —
        /// where a wrong shift offsets every column by the same small
        /// constant — can't ride it into a false lock.
        var alignColumnTolerance: UInt8 = 8
        /// Fraction of columns that must move before fixed side chrome is
        /// excluded from alignment (5/16 — the legacy 5-of-16 at the floor).
        var minMovingFraction = 5.0 / 16.0
        /// Sticky bands are capped to this fraction of the frame height.
        var maxStickyFraction = 1.0 / 3.0
        /// Alignments are scored on informative rows (signature differs from
        /// the row above). Below this many, fall back to the all-rows ratio.
        var minInformativeRows = 4
        /// Of the informative rows at a candidate shift, at least this
        /// fraction must match EXACTLY (zero churn columns). The churn
        /// tolerance alone lets a narrow text bubble (touching ≤
        /// `maxChurn` columns) "match" blank rows, so a tiny false
        /// shift could win on whitespace-heavy pages; at the true shift,
        /// content rows away from the churn band match exactly.
        ///
        /// 0.40 (was 0.50): lower page sections on real docs sites (code
        /// blocks, embedded figures) re-render a few pixels per row when
        /// scrolled, so a GENUINE, uniquely-peaked alignment can land at ~0.45
        /// exact (measured 0.454 on a real PingIdentity capture, with a healthy
        /// 0.66 churn-tolerant match) — and `matchRatio` rejecting it strands
        /// the frontier and drops the rest of the page. The false-lock margin
        /// stays wide: at the true shift exact was 0.45 while every wrong shift
        /// scored ≤0.05, and `matchRatio` (0.60) independently rejects the wrong
        /// shifts (they matched ≤0.57). `minOverlapRows` and informative-row
        /// scoring remain the structural guards.
        var minExactMatchFraction = 0.4
        /// CONSTRAINED (auto) mode only — match floor for the unique-peak ratio
        /// accept in the bounded candidate search. Gmail-class heavy re-render
        /// (cursor-hover band, row-tint flips, dense text re-rendering) caps
        /// the TRUE shift at ~0.75–0.78 match — under every standard bar —
        /// while every non-adjacent rival stayed ≤0.35; the session died
        /// exactly like the byte-exact PingIdentity failure. Manual mode
        /// never uses this accept: its unconstrained search keeps the
        /// strict bars (whitespace-heavy pages score high at many wrong
        /// shifts, but they also fail the rival-ratio test).
        var constrainedMatchFloor = 0.65
        /// Unique-peak (Lowe-style) ratio accept: the best candidate is taken
        /// despite failing the standard bars when every non-adjacent rival's
        /// match is at most this fraction of the best's. Repetitive content
        /// (row-pitch aliases, repeated cards) produces comparable rivals and
        /// can't qualify.
        var constrainedRivalFactor = 0.7
        /// Escape hatch for the exact-match guard: a shift whose match ratio is
        /// at least this high AND whose exact-match vote peak uniquely dominates
        /// every other (non-adjacent) shift is accepted even when its exact
        /// fraction is below `minExactMatchFraction`. Antialiased text re-renders
        /// at a new sub-pixel phase on fractional-scroll pages, so a GENUINE,
        /// uniquely-peaked alignment can match ~99% of rows within tolerance
        /// while only ~30-45% are pixel-exact (measured 0.37 exact / 0.998 match
        /// on the real PingIdentity footer). The exact guard alone rejected it,
        /// stranding the frontier and dropping the page tail. Match-ratio is the
        /// fidelity signal; vote dominance is the uniqueness signal — a repeated
        /// banner false-lock produces MULTIPLE comparable peaks, not one, so it
        /// can't qualify.
        var dominanceMatchRatio = 0.9
        /// The dominant peak's exact-match votes must be at least this multiple
        /// of the best non-adjacent shift's votes to count as unique.
        var dominanceVoteFactor = 3.0
        /// Shifts within this many rows of the peak are its ±sub-pixel shoulders
        /// (the same alignment), not competitors — excluded from the dominance
        /// comparison.
        var dominanceAdjacency = 4
        /// Per-sample-pixel grayscale delta tolerated as "unchanged" when
        /// comparing a frame to the seed for fixed-side-chrome detection —
        /// absorbs sub-pixel antialiasing on fractional-scroll pages.
        var fixedColumnTolerance = 24
        /// A column is fixed side chrome if, across the whole session, the
        /// fraction of rows that ever differed from the SEED frame stays within
        /// this margin of the baseline floor (the floor is whatever full-width
        /// chrome — a footer bar — perturbs every column by). Truly-fixed
        /// nav/TOC columns sit at the floor; scrolling article content (text AND
        /// figures) differs from the seed far more. Kept small and biased so
        /// real content is never blanked — at worst a faint chrome remnant
        /// survives near content. Only edge-anchored runs of such columns are
        /// blanked, never interior content.
        var fixedColumnMargin = 0.018
        /// De-duplication engages only when the baseline floor (the smallest
        /// per-column diff-from-seed) is below this — i.e. some column barely
        /// changed, so real fixed chrome exists. On an ordinary page where every
        /// column scrolls, the floor is high and nothing is blanked.
        var fixedColumnFloorMax = 0.10
        /// Fraction of seed rows a low-diff column must differ in (vertical
        /// STRUCTURE) before it can be chrome. Real nav/TOC columns have text
        /// down the whole strip (structure in a large share of rows); a
        /// terminal's ragged-right margin has only its longest lines' glyph
        /// tips (measured 3% of rows on a real iTerm capture that got falsely
        /// blanked — the old any-single-row test passed on those tips).
        var fixedColumnMinStructuredFraction = 0.08
        /// End-of-content recovery (`appendFinalTail`): once the page has
        /// stopped, the final frame is accepted at its HIGHEST-match-ratio
        /// alignment (ignoring the exact-match guard and the smallest-shift /
        /// vote tiebreak) if it clears this. Dynamic content that re-renders the
        /// overlap (chat re-layout, antialiasing) drops pixel-exactness and can
        /// let a repetitive false peak out-vote the true shift, so the normal
        /// path drops the final tail; this rescues it. Only the final frame, only
        /// at a confirmed stop — so it can't affect mid-page alignment.
        var permissiveMatchRatio = 0.85
    }

    /// The sampled grayscale pixels of one row, one byte per column lane (up to
    /// 64). Equality and hashing derive from the SIMD vector; per-column
    /// agreement between two rows is a lane-wise compare. Unused lanes are 0 in
    /// every signature, so they never differ and are naturally excluded.
    struct RowSig: Equatable, Hashable {
        var lanes = SIMD64<UInt8>()

        /// Number of sampled columns whose pixel differs from `other`'s.
        func churnColumns(vs other: RowSig) -> Int {
            Self.nonzeroLaneCount(lanes ^ other.lanes)
        }

        /// Disagreeing columns counted only where `mask`'s lane is non-zero —
        /// i.e. ignoring columns the caller flagged as fixed chrome (a
        /// sidebar/TOC that doesn't scroll). With an all-`0xFF` mask this is
        /// identical to `churnColumns(vs:)`.
        func churnColumns(vs other: RowSig, mask: SIMD64<UInt8>) -> Int {
            Self.nonzeroLaneCount((lanes ^ other.lanes) & mask)
        }

        /// Masked disagreement count treating per-column deltas of at most
        /// `tolerance` gray levels as agreement (antialiasing re-phase noise
        /// — see `Params.alignColumnTolerance`) — but ONLY on rows anchored
        /// by at least one byte-exact counted column. AA noise dithers
        /// AROUND identical pixels (measured 91% byte-identical at the true
        /// shift), so genuine rows always carry exact columns; a smooth
        /// gradient (or hashed test gray) at a WRONG shift offsets every
        /// column by the same small constant — zero exact columns — and
        /// must not read as agreement. The `mask` must cover only REAL
        /// sampled columns (unused zero lanes would anchor every row).
        /// `tolerance` 0 is identical to `churnColumns(vs:mask:)`.
        func churnColumns(vs other: RowSig, mask: SIMD64<UInt8>, tolerance: UInt8) -> Int {
            let differing = Self.nonzeroLaneCount((lanes ^ other.lanes) & mask)
            guard differing < Self.nonzeroLaneCount(mask) else { return differing }
            let delta = pointwiseMax(lanes, other.lanes) &- pointwiseMin(lanes, other.lanes)
            let over = delta.replacing(with: SIMD64<UInt8>.zero,
                                       where: delta .<= SIMD64<UInt8>(repeating: tolerance))
            return Self.nonzeroLaneCount(over & mask)
        }

        /// Number of lanes whose byte is non-zero (≤ 64, fits a UInt8 sum).
        static func nonzeroLaneCount(_ v: SIMD64<UInt8>) -> Int {
            let ones = SIMD64<UInt8>.zero.replacing(
                with: SIMD64<UInt8>(repeating: 1), where: v .!= SIMD64<UInt8>.zero)
            return Int(ones.wrappedSum())
        }

        /// Each non-zero lane of `v` becomes `0xFF`, zero lanes `0x00` — turns a
        /// per-column "differs?" accumulator into a churn mask keeping only the
        /// moving columns.
        static func laneMask(_ v: SIMD64<UInt8>) -> SIMD64<UInt8> {
            SIMD64<UInt8>.zero.replacing(
                with: SIMD64<UInt8>(repeating: 0xFF), where: v .!= SIMD64<UInt8>.zero)
        }
    }

    /// `appendedRows(n)` reports the stitched-height DELTA: the new rows an
    /// extension added (either direction), or 0 for an interior refresh
    /// (re-scrolling through already-captured content).
    enum AppendResult: Equatable {
        case appendedRows(Int)
        case duplicate
        case noOverlap
        case capReached
    }

    private enum Shift {
        case down(Int)   // content moved up: cur[i] == prev[i + dy]
        case up(Int)     // content moved down: prev[i] == cur[i + k]
    }

    private let params: Params
    private var frameWidth = 0
    private var frameHeight = 0
    private var sampleCount = 16
    private var prevSigs: [RowSig] = []
    /// Per-column churn mask (one `0xFF` lane per moving column) for the current
    /// append, excluding fixed side chrome. Defaults to every USED lane
    /// (`usedLaneMask`) unless `computeAlignMask` finds enough static columns.
    private var alignMask = SIMD64<UInt8>(repeating: 0xFF)
    /// `0xFF` in the lanes that carry real sampled columns (`sampleCount` of
    /// them), 0 beyond. The align mask never exceeds this: unused lanes are 0
    /// in every signature, and the tolerance anchor in
    /// `churnColumns(vs:mask:tolerance:)` must not see them as byte-exact
    /// columns.
    private var usedLaneMask = SIMD64<UInt8>(repeating: 0xFF)
    /// The live canvas; rows are top-down image pixel rows.
    private var canvas: CGContext?
    private var canvasCapacityRows = 0
    /// Signature of each drawn canvas row (nil = never drawn) — the search
    /// space for re-anchoring after the reference frame falls behind.
    private var canvasSigs: [RowSig?] = []
    /// Filled content range within the canvas (top-down rows).
    private var physStart = 0
    private var physEnd = 0
    /// Canvas row where the last appended frame's row 0 sits.
    private var prevBase = 0
    /// The first appended frame and its signatures, kept for fixed-side-chrome
    /// detection (every later frame is compared to the seed) and so finish() can
    /// restamp a clean top-of-page copy of the chrome.
    private var firstFrame: CGImage?
    private var seedSigs: [RowSig] = []
    /// Per-sampled-column running max, over all later frames, of the fraction of
    /// rows that differ from the seed beyond `fixedColumnTolerance`. Low → the
    /// column never changed (fixed chrome); high → it scrolled (content).
    private var seedColumnMaxDiff = [Double](repeating: 0, count: 64)

    /// Total height of the stitched output so far, in pixels.
    var stitchedHeight: Int { physEnd - physStart }

    /// Whether the last `append` saw the content at a different scroll
    /// position than the frame before it. False for duplicates AND for
    /// in-place re-anchors — a static page whose animated elements (video
    /// thumbnails, carousels) defeat the pixel-identical duplicate check.
    /// The auto-scroll policy uses this to detect end-of-content stalls.
    private(set) var lastAppendMoved = false
    /// Deepest sticky top band ever detected, locked for the session.
    /// Per-pair detection misses a band when its pixels change between two
    /// samples (a scroll shadow under a masthead, an animating element in
    /// the chrome) — and a header that slips through once is stamped into
    /// the content AND pollutes re-anchor votes with repeated-header
    /// matches. Fixed chrome doesn't un-fix itself mid-scroll, so the
    /// deepest observed band is excluded from drawing, alignment, and
    /// voting for the rest of the session.
    private var lockedTopBand = 0

    /// Feedforward constraint from AUTO scrolling: the commanded per-step
    /// advance in FRAME pixels. When set, the shift search only considers
    /// down-shifts inside `expectedShiftWindow` — a commanded step can't
    /// legitimately land anywhere else, so repetitive-content false peaks and
    /// sticky-band echoes are never candidates (the wrong-offset duplication
    /// class). Identical frames still short-circuit as duplicates BEFORE
    /// matching; up-shifts and whole-canvas re-anchoring are disabled (an
    /// auto session only advances). Manual mode leaves this nil and keeps the
    /// unconstrained search.
    var expectedShift: Int? {
        didSet { commandedStepsAhead = 1 }
    }
    /// How many commanded steps the incoming frame should sit past the
    /// reference. The reference only advances on a successful stitch, and
    /// only the CONTROLLER knows how many injections happened since then —
    /// it sets this before each append (1 in the healthy case).
    var commandedStepsAhead = 1

    /// Current window: `[base/4, base×stepsAhead + tolerance]`. The generous
    /// lower edge admits partial advances (a grab mid smooth-scroll, the
    /// bottom-of-page clamp); the upper edge is the duplication-killer — it
    /// tracks the accumulated commanded distance and nothing beyond it is
    /// ever a candidate.
    var expectedShiftWindow: ClosedRange<Int>? {
        guard let e = expectedShift, e > 0 else { return nil }
        let accumulated = e * max(1, commandedStepsAhead)
        return max(1, e / 4)...(accumulated + max(24, e / 2))
    }

    // MARK: - Decision trace (diagnostics)

    /// Compact account of the last append's alignment decision — the vote
    /// leaders each search saw and why every verified candidate was accepted
    /// or refused. Rebuilt per append; the controller writes it to the
    /// scroll-capture log on failed appends (and on every append when frame
    /// dumping is enabled), so a field failure carries its own forensics.
    /// String assembly is trivial next to the per-frame pixel work.
    private(set) var appendTrace: [String] = []
    private func trace(_ line: String) { appendTrace.append(line) }
    private static func pct(_ v: Double) -> String { String(format: "%.2f", v) }
    private func traceScore(_ label: String, _ verdict: String, shift: Int, _ s: ShiftScore) {
        trace("\(label): \(verdict) \(shift) match=\(Self.pct(s.matchInformative)) "
            + "exact=\(Self.pct(s.exactInformative)) inf=\(s.informative) all=\(Self.pct(s.matchAll))")
    }
    /// The frame-level context line every append starts with.
    private func traceFrameContext(sameIdx: Int, top: Int, bottom: Int) {
        let maskCols = RowSig.nonzeroLaneCount(alignMask)
        trace("frame: same-idx \(sameIdx)/\(frameHeight), sticky top=\(top) bottom=\(bottom) "
            + "locked=\(lockedTopBand), mask=\(maskCols >= sampleCount ? "all" : "\(maskCols) moving cols"), "
            + "window=\(expectedShiftWindow.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "none"), "
            + "stepsAhead=\(commandedStepsAhead)")
    }
    /// Top vote-getters for a search, so a failure shows what the peaks were.
    private func traceVoteLeaders(_ label: String, _ votes: [Int: Int]) {
        let leaders = votes.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.prefix(5)
            .map { "\($0.key)r×\($0.value)" }.joined(separator: " ")
        trace("\(label): \(votes.count) voted shifts, leaders [\(leaders.isEmpty ? "none" : leaders)]")
    }

    init(params: Params = Params()) {
        self.params = params
    }

    /// Columns sampled per row for a given frame width: `width / pixelsPerSample`,
    /// clamped to `[minSamples, maxSamples]`. Constant within a session (frame
    /// size can't change), so it doubles as the threshold denominator.
    static func sampleCount(forWidth width: Int, params: Params) -> Int {
        min(max(width / params.pixelsPerSample, params.minSamples), params.maxSamples)
    }

    /// Sampled columns allowed to disagree in a matching row, scaled to the
    /// current sample count (3 at 16 samples, ~12 at 64).
    private var maxChurn: Int { Int((params.maxChurnFraction * Double(sampleCount)).rounded()) }
    /// Moving-column floor before fixed side chrome is masked out (5 at 16, ~20 at 64).
    private var minMoving: Int { Int((params.minMovingFraction * Double(sampleCount)).rounded()) }

    func append(_ frame: CGImage) -> AppendResult {
        appendTrace = []
        lastAppendMoved = false
        guard let sigs = rowSignatures(of: frame) else {
            trace("row signatures failed")
            return .noOverlap
        }

        guard canvas != nil else {
            frameWidth = frame.width
            frameHeight = frame.height
            sampleCount = Self.sampleCount(forWidth: frame.width, params: params)
            var used = SIMD64<UInt8>()
            for k in 0..<sampleCount { used[k] = 0xFF }
            usedLaneMask = used
            guard reallocate(capacityRows: frame.height, contentAt: 0) else { return .noOverlap }
            drawFrameRows(0..<frame.height, of: frame, sigs: sigs, atCanvasRow: 0)
            physStart = 0
            physEnd = frame.height
            prevBase = 0
            prevSigs = sigs
            firstFrame = frame
            seedSigs = sigs
            lastAppendMoved = true
            trace("seed \(frame.width)×\(frame.height)")
            return .appendedRows(frame.height)
        }
        guard frame.width == frameWidth, frame.height == frameHeight else {
            trace("frame size mismatch \(frame.width)×\(frame.height) vs \(frameWidth)×\(frameHeight)")
            return .noOverlap
        }
        recordSeedColumnDiff(sigs)

        let h = frameHeight
        var sameIndexMatches = 0
        for i in 0..<h where sigs[i] == prevSigs[i] { sameIndexMatches += 1 }
        if Double(sameIndexMatches) / Double(h) >= params.duplicateRatio {
            trace("duplicate: same-idx \(sameIndexMatches)/\(h)")
            return .duplicate
        }

        // Sticky bands: same-index-identical runs at the frame edges while
        // the middle scrolls. (A run of identical blank rows can false-
        // positive here, but excluding identical content is harmless.)
        let stickyCap = Int(Double(h) * params.maxStickyFraction)
        var top = 0
        while top < stickyCap && sigs[top] == prevSigs[top] { top += 1 }
        var bottom = 0
        while bottom < stickyCap && sigs[h - 1 - bottom] == prevSigs[h - 1 - bottom] { bottom += 1 }
        let effTop = max(top, lockedTopBand)

        computeAlignMask(sigs)
        traceFrameContext(sameIdx: sameIndexMatches, top: top, bottom: bottom)

        let result: AppendResult
        if let shift = findShift(sigs, regionStart: effTop, regionEnd: h - bottom,
                                 frameHeight: h) {
            switch shift {
            case .down(let dy):
                result = appendDown(frame, sigs: sigs, dy: dy, top: effTop, bottom: bottom)
            case .up(let k):
                result = appendUp(frame, sigs: sigs, k: k, top: effTop, bottom: bottom)
            }
        } else if expectedShiftWindow != nil {
            // Constrained (auto) mode: a frame that doesn't match inside the
            // commanded window is a transient (mid-render grab, lazy content
            // churn) — the controller pauses stepping and resamples. Whole-
            // canvas re-anchoring stays off: it's exactly the wrong-offset
            // duplication machine the constraint exists to eliminate.
            trace("no in-window match → noOverlap (transient; controller resamples)")
            return .noOverlap
        } else {
            // The reference frame falls behind after a fast-fling gap (its
            // content was never sampled). Recovery: anchor against the whole
            // canvas, so scrolling back into captured territory resumes the
            // session instead of failing forever.
            guard let base = reanchor(sigs: sigs, top: effTop, bottom: bottom) else {
                return .noOverlap
            }
            result = base >= prevBase
                ? appendDown(frame, sigs: sigs, dy: base - prevBase, top: effTop, bottom: bottom)
                : appendUp(frame, sigs: sigs, k: prevBase - base, top: effTop, bottom: bottom)
        }
        // The band is confirmed as real chrome only once the page MOVED
        // while these rows stayed put — and only if it has structure.
        if lastAppendMoved { lockTopBand(candidate: top, sigs: sigs) }
        return result
    }

    /// PURE fixed-step append (auto mode). Per step there is exactly ONE
    /// check: does the seam line up at the commanded advance (±2px)? Pass →
    /// append there, no searching. Fail → this is (almost always) the
    /// bottom-of-page partial step — the "last step is shorter" caveat — so
    /// run one bounded permissive alignment in [1, commanded+tol]. Identical
    /// frame → `.duplicate` (page-stopped detection, the finish signal).
    /// Sticky top/bottom bands are still trimmed from matching and drawing.
    func appendCommanded(_ frame: CGImage, advance dy: Int) -> AppendResult {
        appendTrace = []
        lastAppendMoved = false
        guard canvas != nil, frame.width == frameWidth, frame.height == frameHeight,
              dy > 0, let sigs = rowSignatures(of: frame) else {
            trace("commanded: precondition failed (canvas/size/advance/signatures)")
            return .noOverlap
        }
        recordSeedColumnDiff(sigs)   // finish()'s side-chrome dedup needs this
        let h = frameHeight
        var same = 0
        for i in 0..<h where sigs[i] == prevSigs[i] { same += 1 }
        if Double(same) / Double(h) >= params.duplicateRatio {
            trace("duplicate: same-idx \(same)/\(h)")
            return .duplicate
        }
        let stickyCap = Int(Double(h) * params.maxStickyFraction)
        var top = 0
        while top < stickyCap && sigs[top] == prevSigs[top] { top += 1 }
        var bottom = 0
        while bottom < stickyCap && sigs[h - 1 - bottom] == prevSigs[h - 1 - bottom] { bottom += 1 }
        let effTop = max(top, lockedTopBand)
        computeAlignMask(sigs)
        traceFrameContext(sameIdx: same, top: top, bottom: bottom)
        // The single per-step fast check: the commanded seam (±2px for
        // fractional scroll rounding). Accept it immediately only when it
        // clears the standard bar. A moderate tolerant match with low exactness
        // is not enough by itself: on sparse documents, Chrome can rescale the
        // wheel delta and the WRONG commanded shift still matches most white
        // rows. Those ambiguous matches must enter the bounded candidate search
        // below, where a stronger measured shift can win. Gmail-class heavy
        // re-render remains supported by that search's unique-peak ratio accept.
        for shift in [dy, dy - 1, dy + 1, dy - 2, dy + 2] where shift >= 1 {
            let s = alignmentScore(lower: prevSigs, upper: sigs, regionStart: effTop,
                                   regionEnd: h - bottom, shift: shift)
            guard passesStandard(s) else { continue }
            traceScore("cmd-seam", "ACCEPT", shift: shift, s)
            return appendDown(frame, sigs: sigs, dy: shift, top: effTop, bottom: bottom)
        }
        traceScore("cmd-seam", "REJECT \(dy)±2 — at", shift: dy, alignmentScore(
            lower: prevSigs, upper: sigs, regionStart: effTop,
            regionEnd: h - bottom, shift: dy))
        // Commanded seam doesn't line up: the bottom partial step, OR the
        // release jump after a scroll-PINNED section ate several steps'
        // budget (in-place animation), OR chrome churn. One bounded
        // permissive alignment, widened by the steps injected since the last
        // match, never beyond the accumulated command.
        let upper = dy * max(1, commandedStepsAhead) + max(24, dy / 2)
        if let s = bestMatchInRegion(lower: prevSigs, upper: sigs,
                                     regionStart: effTop, regionEnd: h - bottom,
                                     window: 1...upper, label: "cmd-fallback") {
            return appendDown(frame, sigs: sigs, dy: s, top: effTop, bottom: bottom)
        }
        trace("cmd-fallback: no acceptable shift → noOverlap")
        return .noOverlap
    }

    /// End-of-content recovery for the FINAL frame: call once when the capture
    /// is ending (the page has stopped scrolling) and the last frame failed the
    /// normal `append` (e.g. its overlap re-rendered, dropping pixel-exactness,
    /// or a repetitive false peak out-voted the true shift). Accepts the
    /// highest match-ratio alignment — ignoring the exact-match guard and the
    /// smallest-shift/vote tiebreak — so the final tail isn't lost. Touches
    /// nothing in the normal path, so mid-page alignment is unaffected.
    func appendFinalTail(_ frame: CGImage) -> AppendResult {
        appendTrace = []
        guard canvas != nil, frame.width == frameWidth, frame.height == frameHeight,
              let sigs = rowSignatures(of: frame) else {
            trace("final-tail: precondition failed (canvas/size/signatures)")
            return .noOverlap
        }
        let h = frameHeight
        var same = 0
        for i in 0..<h where sigs[i] == prevSigs[i] { same += 1 }
        if Double(same) / Double(h) >= params.duplicateRatio {
            trace("final-tail duplicate: same-idx \(same)/\(h)")
            return .duplicate
        }
        let stickyCap = Int(Double(h) * params.maxStickyFraction)
        var top = 0
        while top < stickyCap && sigs[top] == prevSigs[top] { top += 1 }
        var bottom = 0
        while bottom < stickyCap && sigs[h - 1 - bottom] == prevSigs[h - 1 - bottom] { bottom += 1 }
        let effTop = max(top, lockedTopBand)
        computeAlignMask(sigs)
        traceFrameContext(sameIdx: same, top: top, bottom: bottom)
        // Constrained (auto) mode: the final frame can have advanced anything
        // from barely to one full commanded step — allow [1, window.upper],
        // never beyond (and never up).
        let tailWindow = expectedShiftWindow.map { 1...$0.upperBound }
        guard let shift = bestMatchShift(sigs, regionStart: effTop, regionEnd: h - bottom,
                                         window: tailWindow) else {
            trace("final-tail: no acceptable shift → noOverlap (tail dropped)")
            return .noOverlap
        }
        switch shift {
        case .down(let dy): return appendDown(frame, sigs: sigs, dy: dy, top: effTop, bottom: bottom)
        case .up(let k): return appendUp(frame, sigs: sigs, k: k, top: effTop, bottom: bottom)
        }
    }

    /// Permissive alignment for end-of-content recovery: the HIGHEST match-ratio
    /// shift (down preferred), ignoring the exact-match guard and the
    /// smallest-shift/vote tiebreak. Down first, then up.
    private func bestMatchShift(_ sigs: [RowSig], regionStart: Int, regionEnd: Int,
                                window: ClosedRange<Int>? = nil) -> Shift? {
        if let dy = bestMatchInRegion(lower: prevSigs, upper: sigs,
                                      regionStart: regionStart, regionEnd: regionEnd,
                                      window: window, label: "tail-down") {
            return .down(dy)
        }
        if window == nil,
           let k = bestMatchInRegion(lower: sigs, upper: prevSigs,
                                     regionStart: regionStart, regionEnd: regionEnd,
                                     label: "tail-up") {
            return .up(k)
        }
        return nil
    }

    /// The voted shift with the greatest informative match ratio that clears
    /// `permissiveMatchRatio` (and the overlap/informative floors). Same O(h)
    /// voting as `smallestShift`, but selects by match ratio instead of the
    /// smallest passing shift — so a true high-match alignment with low pixel-
    /// exactness, out-voted by a repetitive false peak, is still chosen.
    private func bestMatchInRegion(
        lower: [RowSig], upper: [RowSig], regionStart: Int, regionEnd: Int,
        window: ClosedRange<Int>? = nil, label: String = "permissive"
    ) -> Int? {
        let regionLen = regionEnd - regionStart
        guard regionLen > params.minOverlapRows else {
            trace("\(label): region too small (\(regionLen) ≤ \(params.minOverlapRows))")
            return nil
        }
        let maxShift = regionLen - params.minOverlapRows
        var index: [SIMD64<UInt8>: [Int]] = [:]
        for p in regionStart..<regionEnd where p == regionStart || lower[p] != lower[p - 1] {
            index[lower[p].lanes & alignMask, default: []].append(p)
        }
        var votes: [Int: Int] = [:]
        for i in 0..<regionLen {
            let u = regionStart + i
            guard let rows = index[upper[u].lanes & alignMask] else { continue }
            for p in rows where p - u >= 1 && p - u <= maxShift { votes[p - u, default: 0] += 1 }
        }
        if let window { votes = votes.filter { window.contains($0.key) } }
        traceVoteLeaders(label, votes)
        var best: (shift: Int, match: Double)?
        var scored: [(shift: Int, match: Double)] = []
        var rejectsTraced = 0
        for sh in votes.filter({ $0.value >= 2 }).sorted(by: { $0.value > $1.value }).prefix(64).map(\.key) {
            let s = alignmentScore(lower: lower, upper: upper,
                                   regionStart: regionStart, regionEnd: regionEnd, shift: sh)
            if s.informative >= params.minInformativeRows {
                scored.append((sh, s.matchInformative))
            }
            // Accept a near-perfect fit OR a standard-guard fit (tolerant
            // match + pixel-exact floor). The permissive bar alone froze a
            // real capture (YouTube, frame-dump verified): per-step row
            // re-rendering held the TRUE shift at ~0.83 match while 80% of
            // its rows were pixel-EXACT — and wrong shifts scored ≤0.17
            // match / ≤0.02 exact, so the exact floor keeps false fits out.
            guard s.informative >= params.minInformativeRows,
                  s.matchInformative >= params.permissiveMatchRatio
                    || (s.matchInformative >= params.matchRatio
                        && s.exactInformative >= params.minExactMatchFraction)
            else {
                if rejectsTraced < 4 { traceScore(label, "reject", shift: sh, s); rejectsTraced += 1 }
                continue
            }
            if best == nil || s.matchInformative > best!.match { best = (sh, s.matchInformative) }
        }
        if let best {
            trace("\(label): BEST \(best.shift) match=\(Self.pct(best.match))")
            return best.shift
        }
        // CONSTRAINED (auto) mode only: unique-peak ratio accept. The window
        // has already fenced the candidates to physically possible advances;
        // a moderate-match best with NO comparable rival is the true shift
        // under heavy re-render (Gmail-class: hover band + row-tint flips cap
        // it at ~0.75 while non-adjacent rivals stay ≤0.35). Ambiguous
        // content (whitespace-heavy pages, repeated cards) scores comparable
        // rivals and fails the ratio, so it can't false-lock here.
        if window != nil,
           let top = scored.max(by: { $0.match < $1.match }),
           top.match >= params.constrainedMatchFloor {
            let rival = scored
                .filter { abs($0.shift - top.shift) > params.dominanceAdjacency }
                .map(\.match).max() ?? 0
            if rival <= params.constrainedRivalFactor * top.match {
                trace("\(label): ratio-ACCEPT \(top.shift) match=\(Self.pct(top.match)) "
                    + "(best rival \(Self.pct(rival)))")
                return top.shift
            }
            trace("\(label): ratio refuses \(top.shift) match=\(Self.pct(top.match)) "
                + "(rival \(Self.pct(rival)) too close)")
        }
        trace("\(label): no candidate cleared the permissive/standard bars")
        return nil
    }

    /// Promote a per-pair sticky band to the session lock. Blank runs are
    /// identical across any scroll and would lock a false band that
    /// permanently shrinks the alignment region — require visual structure
    /// (several distinct row signatures) before believing it's chrome.
    private func lockTopBand(candidate top: Int, sigs: [RowSig]) {
        guard top > lockedTopBand else { return }
        var distinct = 1
        for i in 1..<top where sigs[i] != sigs[i - 1] { distinct += 1 }
        guard distinct >= params.minInformativeRows else { return }
        lockedTopBand = top
    }

    /// The stitched image: the filled rows of the canvas, copied out so the
    /// result doesn't pin the (possibly larger) canvas backing store. Fixed
    /// side chrome (sidebar/TOC) is shown once in the first viewport and blanked
    /// below, so it isn't re-stamped down the page.
    func finish() -> CGImage? {
        guard let canvas, stitchedHeight > 0,
              let full = canvas.makeImage(),
              let filled = full.cropping(to: CGRect(
                x: 0, y: physStart, width: frameWidth, height: stitchedHeight)),
              let out = CGContext(
                data: nil, width: frameWidth, height: stitchedHeight, bitsPerComponent: 8,
                bytesPerRow: 4 * frameWidth, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        out.draw(filled, in: CGRect(x: 0, y: 0, width: frameWidth, height: stitchedHeight))
        deduplicateFixedSideChrome(out)
        return out.makeImage()
    }

    // MARK: - Fixed side-chrome de-duplication

    /// Accumulate, per sampled column, the running max over frames of the
    /// fraction of rows that differ from the SEED frame beyond tolerance. A
    /// truly-fixed column (nav/TOC) matches the seed in every frame; scrolling
    /// content (text and figures alike) differs from the seed wherever its
    /// content sits there. Comparing to the SEED (not the previous frame) is
    /// what lets a figure's uniform regions still read as content — they differ
    /// from the seed's top-of-page content.
    private func recordSeedColumnDiff(_ sigs: [RowSig]) {
        guard sigs.count == seedSigs.count, frameHeight > 0 else { return }
        let tol = params.fixedColumnTolerance
        let h = frameHeight
        for k in 0..<sampleCount {
            var diff = 0
            for r in 0..<h where abs(Int(sigs[r].lanes[k]) - Int(seedSigs[r].lanes[k])) > tol { diff += 1 }
            let frac = Double(diff) / Double(h)
            if frac > seedColumnMaxDiff[k] { seedColumnMaxDiff[k] = frac }
        }
    }

    /// Keep fixed side chrome once in the first viewport, blank it below. The
    /// chrome columns are the LEADING and TRAILING edge runs that stayed within
    /// `fixedColumnMargin` of the baseline floor (see `seedColumnMaxDiff`); the
    /// runs stop at the first column that clearly scrolled, so interior content
    /// — including wide figures and ragged-right text — is never blanked. A
    /// single clean copy is restamped from the SEED (top-of-page, no footer).
    private func deduplicateFixedSideChrome(_ out: CGContext) {
        guard frameHeight > 0, stitchedHeight > frameHeight, sampleCount > 1,
              let seed = firstFrame else { return }
        let n = sampleCount
        let floor = (0..<n).map { seedColumnMaxDiff[$0] }.min() ?? 0
        guard floor <= params.fixedColumnFloorMax else { return }   // no truly-fixed column → no chrome
        let chromeT = floor + params.fixedColumnMargin
        // A column is fixed chrome only if it barely changed from the seed AND
        // has vertical STRUCTURE in the seed — a blank margin / whitespace gutter
        // is also low-diff but must not be treated as chrome (else a sparse page
        // with white margins gets falsely blanked, and the gutter before a TOC
        // bridges content into the chrome run). Structure must cover a real
        // FRACTION of rows, not any single one: a terminal's ragged-right
        // margin is background except its longest lines' glyph tips (~3% of
        // rows on the real capture that got falsely blanked), while genuine
        // nav/TOC columns have text down the whole strip.
        var seedStructured = [Bool](repeating: false, count: n)
        if !seedSigs.isEmpty {
            let needed = max(1, Int((Double(seedSigs.count)
                * params.fixedColumnMinStructuredFraction).rounded(.up)))
            for k in 0..<n {
                let first = seedSigs[0].lanes[k]
                var rows = 0
                for r in 1..<seedSigs.count where seedSigs[r].lanes[k] != first {
                    rows += 1
                    if rows >= needed { seedStructured[k] = true; break }
                }
            }
        }
        func chrome(_ k: Int) -> Bool { seedColumnMaxDiff[k] <= chromeT && seedStructured[k] }
        // leading run of chrome columns from the left edge
        var leftEnd = -1
        for k in 0..<n { if chrome(k) { leftEnd = k } else { break } }
        // trailing run of chrome columns from the right edge
        var rightStart = n
        for k in stride(from: n - 1, through: 0, by: -1) { if chrome(k) { rightStart = k } else { break } }
        guard leftEnd >= 0 || rightStart < n else { return }
        func colX(_ k: Int) -> Int { (frameWidth * (2 * k + 1)) / (2 * n) }
        // Cut at the last/first CHROME sample column rather than the gutter
        // midpoint, so the ~half-sample of content nearest the chrome is never
        // trimmed (at worst a thin chrome sliver in the gutter survives).
        let leftX = leftEnd >= 0 ? colX(leftEnd) : 0
        let rightX = rightStart < n ? colX(rightStart) : frameWidth
        let topY = stitchedHeight - frameHeight   // CG y of the first viewport's bottom edge
        out.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        if leftX > 0 {
            out.fill(CGRect(x: 0, y: 0, width: leftX, height: stitchedHeight))
            if let band = seed.cropping(to: CGRect(x: 0, y: 0, width: leftX, height: frameHeight)) {
                out.draw(band, in: CGRect(x: 0, y: topY, width: leftX, height: frameHeight))
            }
        }
        if rightX < frameWidth {
            let rw = frameWidth - rightX
            out.fill(CGRect(x: rightX, y: 0, width: rw, height: stitchedHeight))
            if let band = seed.cropping(to: CGRect(x: rightX, y: 0, width: rw, height: frameHeight)) {
                out.draw(band, in: CGRect(x: rightX, y: topY, width: rw, height: frameHeight))
            }
        }
    }

    // MARK: - Directional appends

    /// The vertical shift the last successful append aligned at (dy for
    /// down, −k for up; 0 for duplicates). Diagnostics only.
    private(set) var lastAppendShift = 0

    /// Recent single-injection accepted advances that deviated from the
    /// commanded distance (kept to the last 3). Some scrollers advance a
    /// CONSISTENTLY different distance than commanded (the PingIdentity
    /// modal moved 128px per 168px command) — every step then misses the
    /// cheap commanded-seam check and pays the full fallback search
    /// (~261ms/step optimized). Three consecutive accepts within ±2 of each
    /// other retarget `expectedShift` to the measured advance so the seam
    /// check hits again; an isolated stray (bottom clamp, pinned-section
    /// release jump) never retargets.
    private var offCommandAdvances: [Int] = []

    /// Track an accepted single-step advance and retarget the feedforward
    /// once the deviation is consistent. Called on every down-append while
    /// commanded (auto) mode is active.
    private func adaptExpectedShift(accepted dy: Int) {
        guard let e = expectedShift, commandedStepsAhead <= 1, dy > 0 else { return }
        if abs(dy - e) <= 2 {
            offCommandAdvances.removeAll()
            return
        }
        offCommandAdvances.append(dy)
        if offCommandAdvances.count > 3 { offCommandAdvances.removeFirst() }
        guard offCommandAdvances.count == 3, let first = offCommandAdvances.first,
              offCommandAdvances.allSatisfy({ abs($0 - first) <= 2 }) else { return }
        trace("adapt: commanded advance \(e) → \(dy) (3 consistent off-command steps)")
        expectedShift = dy
        offCommandAdvances.removeAll()
    }

    private func appendDown(
        _ frame: CGImage, sigs: [RowSig], dy: Int, top: Int, bottom: Int
    ) -> AppendResult {
        lastAppendShift = dy
        adaptExpectedShift(accepted: dy)
        let h = frameHeight
        var base = prevBase + dy
        let newHeight = max(physEnd, base + h) - physStart
        guard newHeight <= params.maxHeight else { return .capReached }
        if base + h > canvasCapacityRows {
            let needed = (base + h) - physStart
            guard reallocate(capacityRows: max(needed, canvasCapacityRows * 2), contentAt: 0)
            else { return .noOverlap }
            base = prevBase + dy
        }
        let delta = max(0, base + h - physEnd)
        // Bottom band only at the frontier — never stamp a footer mid-content.
        let drawHi = base + h >= physEnd ? h : h - bottom
        // Constrained (auto) mode with real movement draws ONLY the fresh
        // rows. Repainting the whole overlap re-stamps any sticky element
        // BELOW the detected top band (mid-viewport tab bars, a header still
        // transforming during the first steps) at a new offset per append —
        // the duplicated strips. Fresh rows come from the frame's bottom
        // band, where viewport-fixed chrome never sits, so it's painted
        // exactly once (by the seed). In-place refreshes (dy == 0, base
        // unchanged) keep the full repaint — aligned by definition, and how
        // lazy-loading content lands. Manual mode keeps historic behavior.
        let drawLo = (expectedShiftWindow != nil && dy > 0) ? max(top, h - delta) : top
        if drawLo < drawHi {
            drawFrameRows(drawLo..<drawHi, of: frame, sigs: sigs, atCanvasRow: base + drawLo)
        }
        physEnd = max(physEnd, base + h)
        lastAppendMoved = dy != 0
        prevBase = base
        prevSigs = sigs
        return .appendedRows(delta)
    }

    private func appendUp(
        _ frame: CGImage, sigs: [RowSig], k: Int, top: Int, bottom: Int
    ) -> AppendResult {
        lastAppendShift = -k
        let h = frameHeight
        var base = prevBase - k
        let newHeight = physEnd - min(physStart, base + top)
        guard newHeight <= params.maxHeight else { return .capReached }
        if base + top < 0 {
            // Prepend underflow: shift the content down by a frame height of
            // headroom (geometric in practice — each shift covers many appends).
            let shiftDown = max(h, -(base + top))
            guard reallocate(capacityRows: canvasCapacityRows + shiftDown + h,
                             contentAt: physStart + shiftDown)
            else { return .noOverlap }
            base = prevBase - k
        }
        let delta = max(0, physStart - (base + top))
        // Both bands excluded: the top band is fixed chrome (drawn once by
        // the first frame), the bottom band already sits at the frontier.
        drawFrameRows(top..<(h - bottom), of: frame, sigs: sigs, atCanvasRow: base + top)
        physStart = min(physStart, base + top)
        lastAppendMoved = k != 0
        prevBase = base
        prevSigs = sigs
        return .appendedRows(delta)
    }

    /// Manual-mode last resort: the user scrolled forward faster than the 5 fps
    /// sampler could keep the ≥`minOverlapRows` overlap `append` needs, and
    /// hasn't scrolled back to let it re-anchor. Force `frame` in as a fresh
    /// anchor directly below the captured content and continue from there.
    /// This intentionally leaves a SEAM — the skipped rows are gone — so the
    /// controller only calls it after a grace window in which the user could
    /// have recovered cleanly by scrolling back up. No-op (`.noOverlap`) before
    /// a canvas exists or on a frame-size mismatch.
    func reseedForward(_ frame: CGImage) -> AppendResult {
        appendTrace = []
        lastAppendMoved = false
        guard canvas != nil, frame.width == frameWidth, frame.height == frameHeight,
              let sigs = rowSignatures(of: frame) else {
            trace("reseedForward: precondition failed (needs an existing canvas)")
            return .noOverlap
        }
        let h = frameHeight
        if physEnd + h > canvasCapacityRows {
            guard reallocate(capacityRows: max((physEnd + h) - physStart, canvasCapacityRows * 2),
                             contentAt: 0)
            else { return .noOverlap }
        }
        // Place the frame's row 0 immediately below the captured content — base
        // is read AFTER any reallocate, which rewrites physEnd/prevBase.
        let base = physEnd
        drawFrameRows(0..<h, of: frame, sigs: sigs, atCanvasRow: base)
        physEnd = base + h
        prevBase = base
        prevSigs = sigs
        lastAppendMoved = true
        trace("reseedForward: gap-seam, anchor at canvas row \(base), +\(h)")
        return .appendedRows(h)
    }

    // MARK: - Fixed-column masking

    /// Set `alignMask` to exclude columns that are pixel-identical between
    /// `prevSigs` and `sigs` at every row index — fixed side chrome (sidebar,
    /// nav, TOC) on a page where only a sub-region scrolls. Falls back to
    /// all-columns (`0xFF` in every lane) when too few columns move, so blank
    /// or near-static pages keep their existing, well-tested behavior.
    private func computeAlignMask(_ sigs: [RowSig]) {
        alignMask = usedLaneMask
        guard sigs.count == prevSigs.count, !sigs.isEmpty else { return }
        var diff = SIMD64<UInt8>()
        for i in 0..<sigs.count { diff |= sigs[i].lanes ^ prevSigs[i].lanes }
        let moving = RowSig.nonzeroLaneCount(diff)
        guard moving >= minMoving else { return }
        alignMask = RowSig.laneMask(diff)
    }

    // MARK: - Alignment

    /// Direction-aware shift search. Down first (the primary direction), in
    /// the band-trimmed region; then up; then both again over the wider
    /// frame (blank-row runs at the edges can masquerade as sticky bands
    /// and swallow the search range — drawing still excludes the detected
    /// bands, so real chrome is never re-stamped). The wider retry still
    /// floors at the session-locked band: repeated fixed chrome aligning
    /// with itself produces confident WRONG shifts.
    private func findShift(
        _ sigs: [RowSig], regionStart: Int, regionEnd: Int, frameHeight h: Int
    ) -> Shift? {
        let window = expectedShiftWindow
        if regionEnd - regionStart > params.minOverlapRows {
            if let dy = smallestShift(lower: prevSigs, upper: sigs,
                                      regionStart: regionStart, regionEnd: regionEnd,
                                      window: window, label: "down") {
                return .down(dy)
            }
            // Up-shifts can't happen in constrained (auto) mode — only the
            // commanded downward advance is a legitimate movement.
            if window == nil,
               let k = smallestShift(lower: sigs, upper: prevSigs,
                                     regionStart: regionStart, regionEnd: regionEnd,
                                     label: "up") {
                return .up(k)
            }
        }
        if let dy = smallestShift(lower: prevSigs, upper: sigs,
                                  regionStart: lockedTopBand, regionEnd: h,
                                  window: window, label: "down-wide") {
            return .down(dy)
        }
        if window == nil,
           let k = smallestShift(lower: sigs, upper: prevSigs,
                                 regionStart: lockedTopBand, regionEnd: h,
                                 label: "up-wide") {
            return .up(k)
        }
        return nil
    }

    /// Smallest positive shift where `upper[i]` matches `lower[i + shift]`
    /// inside the region — i.e. `upper`'s content appears `shift` rows lower
    /// in `lower`. Scored over informative rows only (rows whose signature
    /// differs from the row above), so runs of identical blank rows cast one
    /// vote instead of hundreds and can't carry a false alignment. A row
    /// matches when at most `maxChurn` sampled columns disagree, so a
    /// narrow viewport-fixed overlay can't veto every row it crosses.
    private func smallestShift(
        lower: [RowSig], upper: [RowSig], regionStart: Int, regionEnd: Int,
        window: ClosedRange<Int>? = nil, label: String = "search"
    ) -> Int? {
        let regionLen = regionEnd - regionStart
        guard regionLen > params.minOverlapRows else {
            trace("\(label): region too small (\(regionLen) ≤ \(params.minOverlapRows))")
            return nil
        }
        let maxShift = regionLen - params.minOverlapRows

        // O(regionLen) candidate search: index `lower`'s informative rows by
        // their mask-aware signature, then let each `upper` row vote for the
        // shift that gives it an exact (churn-0) match. A shift's vote count
        // equals its exact-informative-match count, and the acceptance test
        // needs ≥2 of those — so voted shifts are a SUPERSET of acceptable
        // ones. Replaces an O(regionLen²) scan over every shift; `reanchor`
        // votes the same way against the whole canvas.
        var index: [SIMD64<UInt8>: [Int]] = [:]
        for p in regionStart..<regionEnd where p == regionStart || lower[p] != lower[p - 1] {
            index[lower[p].lanes & alignMask, default: []].append(p)
        }
        var votes: [Int: Int] = [:]
        for i in 0..<regionLen {
            let u = regionStart + i
            guard let rows = index[upper[u].lanes & alignMask] else { continue }
            for p in rows where p - u >= 1 && p - u <= maxShift { votes[p - u, default: 0] += 1 }
        }
        // Feedforward constraint (auto mode): shifts outside the commanded
        // window are physically impossible — drop them before any scoring so
        // repetitive false peaks and sticky-band echoes can't win.
        if let window { votes = votes.filter { window.contains($0.key) } }
        traceVoteLeaders(label, votes)
        // Fast path: the commanded distance is the overwhelmingly likely
        // truth — verify it directly (±2px for fractional rounding) before
        // any vote-based search.
        if window != nil, let e = expectedShift {
            let center = e * max(1, commandedStepsAhead)
            for shift in [center, center - 1, center + 1, center - 2, center + 2]
            where shift >= 1 && shift <= maxShift && shiftPasses(
                lower: lower, upper: upper, regionStart: regionStart,
                regionEnd: regionEnd, shift: shift) {
                traceScore(label, "ACCEPT (commanded fast-path)", shift: shift, alignmentScore(
                    lower: lower, upper: upper, regionStart: regionStart,
                    regionEnd: regionEnd, shift: shift))
                return shift
            }
            traceScore(label, "commanded center fails — at", shift: center, alignmentScore(
                lower: lower, upper: upper, regionStart: regionStart,
                regionEnd: regionEnd, shift: center))
        }
        // Verification order is the false-peak tiebreak. Unconstrained
        // (manual): smallest-shift-first, the historic behavior. Constrained
        // (auto): NEAREST-TO-COMMANDED first — we know where the true shift
        // is, and a repetitive in-window peak below it must not win just for
        // being smaller (observed as a duplicated mid-image strip).
        let ordered = votes.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }.prefix(64)
            .map(\.key)
        let candidates: [Int]
        if window != nil, let e = expectedShift {
            let center = e * max(1, commandedStepsAhead)
            candidates = ordered.sorted {
                (abs($0 - center), $0) < (abs($1 - center), $1)
            }
        } else {
            candidates = ordered.sorted()
        }
        // Branch A: smallest shift that clears the standard accept criterion.
        var rejectsTraced = 0
        for shift in candidates {
            if shiftPasses(lower: lower, upper: upper,
                           regionStart: regionStart, regionEnd: regionEnd, shift: shift) {
                traceScore(label, "ACCEPT", shift: shift, alignmentScore(
                    lower: lower, upper: upper, regionStart: regionStart,
                    regionEnd: regionEnd, shift: shift))
                return shift
            }
            if rejectsTraced < 4 {
                traceScore(label, "reject", shift: shift, alignmentScore(
                    lower: lower, upper: upper, regionStart: regionStart,
                    regionEnd: regionEnd, shift: shift))
                rejectsTraced += 1
            }
        }
        // Branch B: a single near-perfect alignment whose exact-match vote peak
        // uniquely dominates every non-adjacent shift is accepted even below the
        // exact-match guard (see `dominanceMatchRatio`). Antialiased text re-
        // rendering on fractional scrolls lands here (high match, low exact); a
        // repeated-content false-lock has multiple comparable peaks, so it can't
        // satisfy the dominance test.
        if let peak = votes.max(by: { $0.value < $1.value }), peak.value >= 2 {
            let bestRival = votes
                .filter { abs($0.key - peak.key) > params.dominanceAdjacency }
                .map(\.value).max() ?? 0
            let score = alignmentScore(lower: lower, upper: upper,
                                       regionStart: regionStart, regionEnd: regionEnd, shift: peak.key)
            if score.informative >= params.minInformativeRows,
               score.matchInformative >= params.dominanceMatchRatio,
               Double(peak.value) >= params.dominanceVoteFactor * Double(max(bestRival, 1)) {
                trace("\(label): ACCEPT \(peak.key) via dominance (peak×\(peak.value) "
                    + "vs rival×\(bestRival), match=\(Self.pct(score.matchInformative)))")
                return peak.key
            }
            trace("\(label): dominance fails — peak \(peak.key)×\(peak.value) rival×\(bestRival) "
                + "match=\(Self.pct(score.matchInformative)) exact=\(Self.pct(score.exactInformative))")
        }
        return nil
    }

    private struct ShiftScore {
        let matchInformative: Double
        let exactInformative: Double
        let matchAll: Double
        let informative: Int
    }

    /// Score `shift` over the region: fraction of informative rows (signature
    /// differs from the row above) matching within `maxChurn` columns, fraction
    /// matching EXACTLY, and the all-rows match fraction (the low-informative
    /// fallback).
    private func alignmentScore(
        lower: [RowSig], upper: [RowSig], regionStart: Int, regionEnd: Int, shift: Int
    ) -> ShiftScore {
        let overlap = (regionEnd - regionStart) - shift
        guard overlap > 0 else { return ShiftScore(matchInformative: 0, exactInformative: 0, matchAll: 0, informative: 0) }
        var matchesAll = 0
        var informative = 0
        var matchesInformative = 0
        var exactInformative = 0
        for i in 0..<overlap {
            let p = regionStart + shift + i
            let churn = upper[regionStart + i].churnColumns(
                vs: lower[p], mask: alignMask, tolerance: params.alignColumnTolerance)
            let match = churn <= maxChurn
            if match { matchesAll += 1 }
            if p == 0 || lower[p] != lower[p - 1] {
                informative += 1
                if match { matchesInformative += 1 }
                if churn == 0 { exactInformative += 1 }
            }
        }
        return ShiftScore(
            matchInformative: informative > 0 ? Double(matchesInformative) / Double(informative) : 0,
            exactInformative: informative > 0 ? Double(exactInformative) / Double(informative) : 0,
            matchAll: Double(matchesAll) / Double(overlap),
            informative: informative)
    }

    /// Whether `shift` aligns `upper` onto `lower` under the standard criterion:
    /// at least `matchRatio` of informative rows match within `maxChurn` columns
    /// AND at least `minExactMatchFraction` match exactly; with the all-rows
    /// ratio as a fallback when there are too few informative rows.
    private func shiftPasses(
        lower: [RowSig], upper: [RowSig], regionStart: Int, regionEnd: Int, shift: Int
    ) -> Bool {
        passesStandard(alignmentScore(lower: lower, upper: upper,
                                      regionStart: regionStart, regionEnd: regionEnd, shift: shift))
    }

    private func passesStandard(_ s: ShiftScore) -> Bool {
        if s.informative >= params.minInformativeRows {
            return s.matchInformative >= params.matchRatio && s.exactInformative >= params.minExactMatchFraction
        }
        return s.matchAll >= params.matchRatio
    }

    // MARK: - Canvas

    /// (Re)allocate the canvas with `capacityRows`, placing the existing
    /// filled content so it starts at row `contentAt`. Adjusts the physical
    /// bookkeeping (`physStart`/`physEnd`/`prevBase`) to the new placement.
    private func reallocate(capacityRows: Int, contentAt newStart: Int) -> Bool {
        guard let ctx = CGContext(
            data: nil, width: frameWidth, height: capacityRows, bitsPerComponent: 8,
            bytesPerRow: 4 * frameWidth, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        let filledRows = physEnd - physStart
        if let canvas, filledRows > 0,
           let image = canvas.makeImage(),
           let filled = image.cropping(to: CGRect(
            x: 0, y: physStart, width: frameWidth, height: filledRows)) {
            ctx.draw(filled, in: CGRect(x: 0, y: CGFloat(capacityRows - newStart - filledRows),
                                        width: CGFloat(frameWidth), height: CGFloat(filledRows)))
        }
        var newSigs = [RowSig?](repeating: nil, count: capacityRows)
        if filledRows > 0 {
            newSigs.replaceSubrange(newStart..<(newStart + filledRows),
                                    with: canvasSigs[physStart..<physEnd])
        }
        canvasSigs = newSigs
        prevBase += newStart - physStart
        physEnd = newStart + filledRows
        physStart = newStart
        canvas = ctx
        canvasCapacityRows = capacityRows
        return true
    }

    /// Draw `rows` of `frame` so they occupy canvas rows starting at
    /// `canvasRow` (both top-down; the CG flip happens here, in one place),
    /// and record their signatures for re-anchoring.
    private func drawFrameRows(
        _ rows: Range<Int>, of frame: CGImage, sigs: [RowSig], atCanvasRow canvasRow: Int
    ) {
        guard let canvas, !rows.isEmpty,
              let piece = frame.cropping(to: CGRect(
                x: 0, y: rows.lowerBound, width: frameWidth, height: rows.count))
        else { return }
        canvas.draw(piece, in: CGRect(
            x: 0, y: CGFloat(canvasCapacityRows - canvasRow - rows.count),
            width: CGFloat(frameWidth), height: CGFloat(rows.count)))
        for r in rows {
            canvasSigs[canvasRow + r - rows.lowerBound] = sigs[r]
        }
    }

    /// Recovery search for a frame that doesn't align with the last appended
    /// frame: vote the frame's distinctive rows (rare signatures — blank runs
    /// are ambiguous and don't vote) against the whole canvas, then verify
    /// the winning offset with the standard tolerant + exact-dominance
    /// criterion. Returns the canvas row of the frame's row 0, or nil.
    private func reanchor(sigs: [RowSig], top: Int, bottom: Int) -> Int? {
        let h = sigs.count
        let lo = top, hi = h - bottom
        guard hi - lo > params.minOverlapRows else {
            trace("reanchor: region too small (\(hi - lo) ≤ \(params.minOverlapRows))")
            return nil
        }

        var index: [RowSig: [Int]] = [:]
        for row in physStart..<physEnd {
            if let sig = canvasSigs[row] { index[sig, default: []].append(row) }
        }
        let maxBucket = 32   // sigs common in the canvas can't discriminate
        var votes: [Int: Int] = [:]
        for i in lo..<hi where i == lo || sigs[i] != sigs[i - 1] {
            guard let rows = index[sigs[i]], rows.count <= maxBucket else { continue }
            for row in rows { votes[row - i, default: 0] += 1 }
        }
        // Most votes wins; ties go to the base nearest the current one.
        guard let best = votes.max(by: {
            ($0.value, -abs($0.key - prevBase)) < ($1.value, -abs($1.key - prevBase))
        }), best.value >= params.minInformativeRows else {
            trace("reanchor: no vote winner (best "
                + "\(votes.values.max().map(String.init) ?? "none") < \(params.minInformativeRows))")
            return nil
        }

        let base = best.key
        var overlapRows = 0
        var informative = 0, matches = 0, exact = 0
        for i in lo..<hi {
            let row = base + i
            guard row >= physStart, row < physEnd, let canvasSig = canvasSigs[row]
            else { continue }
            overlapRows += 1
            guard i == lo || sigs[i] != sigs[i - 1] else { continue }
            informative += 1
            let churn = sigs[i].churnColumns(
                vs: canvasSig, mask: alignMask, tolerance: params.alignColumnTolerance)
            if churn <= maxChurn { matches += 1 }
            if churn == 0 { exact += 1 }
        }
        let m = informative > 0 ? Double(matches) / Double(informative) : 0
        let e = informative > 0 ? Double(exact) / Double(informative) : 0
        guard overlapRows > params.minOverlapRows,
              informative >= params.minInformativeRows,
              m >= params.matchRatio,
              e >= params.minExactMatchFraction
        else {
            trace("reanchor: REJECT base=\(base) (votes \(best.value)): overlap=\(overlapRows) "
                + "inf=\(informative) match=\(Self.pct(m)) exact=\(Self.pct(e))")
            return nil
        }
        trace("reanchor: ACCEPT base=\(base) (prev \(prevBase), votes \(best.value)): "
            + "overlap=\(overlapRows) match=\(Self.pct(m)) exact=\(Self.pct(e))")
        return base
    }

    // MARK: - Signatures

    /// `sampleCount(forWidth:params:)` evenly spaced grayscale pixels per row,
    /// packed into a `RowSig`. Scrolled-identical content renders pixel-
    /// identical, so the samples align exactly; the match-ratio threshold
    /// absorbs scattered animation noise and `maxChurn` absorbs narrow fixed
    /// overlays.
    private func rowSignatures(of frame: CGImage) -> [RowSig]? {
        let w = frame.width, h = frame.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)

        let n = Self.sampleCount(forWidth: w, params: params)
        let columns = (0..<n).map { (w * (2 * $0 + 1)) / (2 * n) }
        var sigs = [RowSig](repeating: RowSig(), count: h)
        for row in 0..<h {
            var lanes = SIMD64<UInt8>()
            for (k, col) in columns.enumerated() { lanes[k] = px[row * rowBytes + col] }
            sigs[row] = RowSig(lanes: lanes)
        }
        return sigs
    }
}
