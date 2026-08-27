import XCTest
import CoreGraphics
@testable import Sealshot

/// The scrolling-capture stitching engine, tested against synthetic "pages":
/// a tall source image is sliced into overlapping viewport frames (as if the
/// user scrolled), and the stitched result must reproduce the source.
/// Every source row gets a distinct color so overlap matching is unambiguous
/// and byte-exact reconstruction is assertable.
final class ScrollStitcherTests: XCTestCase {

    private let viewportW = 300
    private let viewportH = 400

    // MARK: - Reconstruction

    func testStitch_overlappingFrames_reproducesSource() {
        let page = makePage(height: 1200)
        let offsets = [0, 150, 320, 560, 800]   // deltas all < viewportH
        let stitcher = ScrollStitcher()
        for off in offsets {
            let result = stitcher.append(slice(page, atRow: off))
            if off == 0 {
                XCTAssertEqual(result, .appendedRows(viewportH))
            } else {
                XCTAssertNotEqual(result, .noOverlap, "offset \(off) should overlap")
            }
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.width, viewportW)
        XCTAssertEqual(out.height, 800 + viewportH)
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<(800 + viewportH))),
                      "stitched bytes differ from source")
    }

    func testStitch_singleFrame_isThatFrame() {
        let page = makePage(height: 600)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 100))
        let out = stitcher.finish()
        XCTAssertEqual(out?.height, viewportH)
        if let out { XCTAssertTrue(imagesEqual(out, crop(page, rows: 100..<500))) }
    }

    // MARK: - Append results

    func testAppend_identicalFrame_isDuplicate() {
        let page = makePage(height: 800)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 0))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 0)), .duplicate)
    }

    /// End-of-content with an animated element (video thumbnail, carousel):
    /// the frame isn't pixel-identical, so the duplicate check can't fire —
    /// but it re-anchors exactly in place. `lastAppendMoved` must expose
    /// that so the auto-scroll policy can still detect the stall.
    func testAppend_staticFrameWithAnimatedBand_reanchorsInPlace_notMoved() {
        let page = makePage(height: 800)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 0))
        XCTAssertTrue(stitcher.lastAppendMoved, "first frame counts as movement")

        // Same position, but a 60-row band (15% — past the 2% duplicate
        // tolerance) "animates" to new content.
        let animated = withBand(slice(page, atRow: 0), rows: 180..<240)
        XCTAssertEqual(stitcher.append(animated), .appendedRows(0),
                       "in-place re-anchor is an interior refresh")
        XCTAssertFalse(stitcher.lastAppendMoved, "the page did not scroll")
    }

    func testAppend_scrolledFrame_reportsMoved() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 0))
        _ = stitcher.append(slice(page, atRow: 150))
        XCTAssertTrue(stitcher.lastAppendMoved)
    }

    /// Manual-mode last-resort recovery: after the user scrolls forward past
    /// the overlap window (a frame that `append` can only report as
    /// `.noOverlap`), `reseedForward` force-anchors that frame below the
    /// captured content so capture continues, and subsequent contiguous frames
    /// stitch onto the new anchor. There is an intentional seam where the
    /// skipped rows were.
    func testReseedForward_afterLostOverlap_continuesFromNewAnchor() {
        let page = makePage(height: 1600)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 0))       // seed  → 400
        _ = stitcher.append(slice(page, atRow: 150))     // +150  → 550
        XCTAssertEqual(stitcher.stitchedHeight, 550)

        // A big forward jump the sampler couldn't bridge: no overlap with the
        // last stitched frame (rows 150..550).
        let jumped = slice(page, atRow: 900)
        XCTAssertEqual(stitcher.append(jumped), .noOverlap)
        XCTAssertEqual(stitcher.stitchedHeight, 550, "a no-overlap frame must not extend the stitch")

        // Force it in as a new anchor.
        XCTAssertEqual(stitcher.reseedForward(jumped), .appendedRows(viewportH))
        XCTAssertEqual(stitcher.stitchedHeight, 950)

        // Continuing to scroll from there stitches normally onto the new anchor.
        XCTAssertEqual(stitcher.append(slice(page, atRow: 1050)), .appendedRows(150))
        XCTAssertEqual(stitcher.stitchedHeight, 1100)
        XCTAssertTrue(stitcher.lastAppendMoved)
    }

    // MARK: - Fixed chrome (sticky headers)

    /// A viewport-fixed masthead sits at the top of EVERY frame. It must
    /// appear exactly once (from the first frame); every later frame's copy
    /// is excluded from drawing.
    func testStitch_fixedHeaderOnEveryFrame_appearsOnce() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        for off in [0, 150, 320] {
            let framed = withHeader(slice(page, atRow: off), rows: 0..<60)
            XCTAssertNotEqual(stitcher.append(framed), .noOverlap, "offset \(off)")
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, 320 + viewportH)
        // Below the one legitimate header, the stitched bytes are pure page
        // content — no header re-stamped at any join.
        XCTAssertTrue(imagesEqual(crop(out, rows: 60..<out.height),
                                  crop(page, rows: 60..<(320 + viewportH))),
                      "fixed header leaked into the content")
    }

    /// One mid-session frame pair fails band detection (the header pixels
    /// changed — e.g. a scroll shadow under a masthead). The band locked
    /// from earlier pairs must still keep the header out of the canvas.
    func testStitch_headerChangesMidSession_lockedBandStillExcludesIt() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(withHeader(slice(page, atRow: 0), rows: 0..<60))
        _ = stitcher.append(withHeader(slice(page, atRow: 150), rows: 0..<60))
        // Same fixed position, visibly different header band → the per-pair
        // detector sees no sticky band for this pair.
        let changed = withHeader(slice(page, atRow: 320), rows: 0..<60, variant: 1)
        XCTAssertNotEqual(stitcher.append(changed), .noOverlap)
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertTrue(imagesEqual(crop(out, rows: 60..<out.height),
                                  crop(page, rows: 60..<(320 + viewportH))),
                      "changed header leaked past the locked band")
    }

    /// A docs-style 3-column page: a FIXED left sidebar AND a fixed right
    /// table-of-contents, spanning together about half the sampled columns —
    /// far more than the narrow-overlay churn tolerance — while only the
    /// center article scrolls. Full-width row matching can never find the
    /// shift (the fixed sides disagree at every non-zero offset), so the
    /// session stitches nothing. Alignment must ignore the static side
    /// columns and lock onto the scrolling center.
    func testStitch_fixedSideColumns_centerScrolls_stillAligns() {
        let centerPage = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(sidebarFrame(centerPage, atRow: 0, sideWidth: 80)),
                       .appendedRows(viewportH))
        XCTAssertEqual(stitcher.append(sidebarFrame(centerPage, atRow: 150, sideWidth: 80)),
                       .appendedRows(150),
                       "fixed side columns must not defeat center-column alignment")
        XCTAssertEqual(stitcher.append(sidebarFrame(centerPage, atRow: 320, sideWidth: 80)),
                       .appendedRows(170))
        XCTAssertEqual(stitcher.stitchedHeight, 320 + viewportH)
    }

    /// Fixed left+right side chrome (nav/TOC) is viewport-fixed, so the stitcher
    /// re-stamps it at every join and it repeats down the page. finish() keeps
    /// it ONCE in the first viewport and blanks it below, identifying chrome by
    /// comparing every frame to the SEED: a fixed column matches the seed in
    /// every frame, while content (text AND figures) differs from it.
    func testFinish_fixedSideChrome_keptAtTopBlankedBelow() {
        let centerPage = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        for off in [0, 150, 320, 500] {
            _ = stitcher.append(sidebarFrame(centerPage, atRow: off, sideWidth: 80))
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.width, viewportW, "full width is kept (chrome shown once, not cropped)")
        XCTAssertEqual(out.height, 500 + viewportH)
        // Left chrome [0,80): a single clean copy up top (matches a fresh frame's
        // band, not tiled re-stamps), blank below.
        let refBand = sidebarFrame(centerPage, atRow: 0, sideWidth: 80)
            .cropping(to: CGRect(x: 0, y: 0, width: 60, height: viewportH))!
        let topLeft = out.cropping(to: CGRect(x: 0, y: 0, width: 60, height: viewportH))!
        XCTAssertTrue(imagesEqual(topLeft, refBand), "kept top nav must be one clean copy")
        let belowLeft = out.cropping(to: CGRect(x: 0, y: viewportH + 20,
                                                width: 60, height: out.height - viewportH - 20))!
        XCTAssertTrue(isAllWhite(belowLeft), "fixed side chrome must be blanked below the first viewport")
        let belowRight = out.cropping(to: CGRect(x: viewportW - 60, y: viewportH + 20,
                                                 width: 60, height: out.height - viewportH - 20))!
        XCTAssertTrue(isAllWhite(belowRight), "fixed right chrome must be blanked below")
    }

    /// A normal full-width page (no fixed side columns) must be untouched —
    /// every column scrolls, so the floor is high and nothing is blanked.
    func testFinish_noFixedSides_unchanged() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        for off in [0, 150, 320] { _ = stitcher.append(slice(page, atRow: off)) }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.width, viewportW)
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<(320 + viewportH))),
                      "no side chrome → output reproduces the source unchanged")
    }

    /// Over-blank guard: a docs page whose article content reaches different
    /// widths down the page (a wide block among narrower text). The wide content
    /// differs from the seed, so it must be kept — only the always-fixed edge
    /// chrome is blanked.
    func testFinish_variableWidthContent_notBlanked() {
        let centerPage = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        for off in [0, 150, 320, 500] {
            _ = stitcher.append(sidebarRaggedFrame(centerPage, atRow: off,
                                                   sideWidth: 70, textRight: 180))
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.width, viewportW)
        let textBelow = out.cropping(to: CGRect(x: 90, y: viewportH + 20,
                                                width: 60, height: out.height - viewportH - 20))!
        XCTAssertTrue(hasNonWhite(textBelow), "article content must not be blanked")
        let chromeBelow = out.cropping(to: CGRect(x: viewportW - 40, y: viewportH + 20,
                                                  width: 40, height: out.height - viewportH - 20))!
        XCTAssertTrue(isAllWhite(chromeBelow), "fixed right chrome must be blanked below")
    }

    /// A terminal's ragged-right margin (real iTerm capture, 2026-07-04):
    /// mostly blank, barely changing, with glyph tips from the longest lines
    /// in only ~3% of rows — it SCROLLS with the content and must never be
    /// classified as fixed side chrome. It was: the any-single-row structure
    /// test passed on the tips, and finish() blanked the lower-right corner.
    func testFinish_terminalRaggedRightMargin_notBlanked() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        for off in [0, 150, 320, 500] {
            XCTAssertNotEqual(
                stitcher.append(terminalMarginFrame(page, atRow: off, marginWidth: 40)),
                .noOverlap, "offset \(off) should align")
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        // The very edge of the margin — where the false classification blanks
        // (from the last low-diff sample column rightward) — must keep its
        // protruding line-ends below the first viewport.
        let edgeBelow = out.cropping(to: CGRect(x: viewportW - 8, y: viewportH + 20,
                                                width: 8, height: out.height - viewportH - 20))!
        XCTAssertTrue(hasNonWhite(edgeBelow),
                      "scrolling ragged-right margin was blanked as fixed chrome")
    }

    /// A near-viewport shift leaves only a sliver of overlap — too little
    /// evidence to trust. If the page has repeated content (chat banners,
    /// identical bubbles), the sliver can match perfectly at a WRONG shift
    /// and stamp duplicated content. Such thin windows must be rejected.
    func testAppend_thinSliverOfRepeatedContent_isNotAccepted() {
        // page rows 600..630 repeat rows 370..400: a 30-row block that
        // falsely "aligns" frame(600) onto frame(0) at shift 370.
        let page = makePage(height: 1200, copying: 370..<400, to: 600)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(slice(page, atRow: 0)), .appendedRows(viewportH))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 600)), .noOverlap,
                       "a 30-row repeated sliver must not pass for an alignment")
        XCTAssertEqual(stitcher.stitchedHeight, viewportH)
    }

    /// A photographic page (Unsplash-style image masonry) re-renders part of
    /// the overlap between consecutive frames: newly revealed images stream in
    /// and photo content resamples, so the CORRECT alignment matches well
    /// under 100% of rows (~0.66 here; 0.679 measured on a real failing
    /// capture) while staying a sharp, unique peak with a high EXACT-match
    /// fraction. The stitcher must accept it — rejecting it as no-overlap on
    /// the first post-seed step falls the whole auto-scroll session back to
    /// manual ("Can't auto-scroll here").
    func testStitch_partiallyRerenderedOverlap_photographicPage_stillAligns() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(slice(page, atRow: 0)), .appendedRows(viewportH))
        // Scrolled by 150; one row in three across the 250-row overlap has
        // re-rendered to new content (lazy-loaded images settling in), so the
        // true shift matches ~2/3 of the overlap rows.
        let scrolled = reRenderRows(slice(page, atRow: 150), rows: 0..<250, everyNth: 3)
        XCTAssertEqual(stitcher.append(scrolled), .appendedRows(150),
                       "a correct, sharply-peaked alignment matching ~2/3 of rows must be accepted")
    }

    /// The true-shift overlap matches within the churn tolerance on every row,
    /// but only ~45% of those rows are pixel-EXACT — above the exact-match
    /// guard (0.40) yet below the old 0.50. Real docs pages hit this on lower
    /// sections (code blocks / figures re-render a few pixels when scrolled);
    /// the genuine, uniquely-peaked alignment must still be accepted, or one
    /// rejection strands the frontier and the rest of the page is dropped.
    func testStitch_highMatchLowExact_stillStitches() {
        let (frame1, frame2) = makeExactBoundaryPair(shift: 150)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(frame1), .appendedRows(churnViewportH))
        XCTAssertEqual(stitcher.append(frame2), .appendedRows(150),
                       "alignment matching within tolerance but only ~45% pixel-exact must be accepted")
    }

    /// The true alignment matches within tolerance on every overlap row and is
    /// the only plausible shift — its exact-match vote peak dwarfs every other
    /// shift — but only ~30% of rows are pixel-EXACT, BELOW the 0.40 exact
    /// guard. Antialiased text on fractional-scroll pages lands here (measured
    /// 0.37 exact / 0.998 match on the real PingIdentity footer). A uniquely
    /// dominant, near-perfect alignment must be accepted on the strength of its
    /// match ratio + vote dominance, or one rejection strands the frontier and
    /// the page tail (the footer) is dropped — the 5415px truncation.
    func testStitch_dominantPeakBelowExactGuard_stillStitches() {
        let (frame1, frame2) = makeExactBoundaryPair(shift: 150, perturbMod: 14)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(frame1), .appendedRows(churnViewportH))
        XCTAssertEqual(stitcher.append(frame2), .appendedRows(150),
                       "a uniquely dominant 99%+-match alignment must stitch even below the exact guard")
    }

    /// The whole page translates by an exact integer offset, but every content
    /// row's antialiasing re-rasterizes at a new phase after each scroll —
    /// half the columns of ~90% of rows shift by 2–6 gray levels. Measured on
    /// a real PingIdentity admin-console modal (Chrome, 2026-07-09 frame
    /// dump): 91% of pixels byte-identical, 99.5% within ≤8 levels — yet
    /// byte-exact scoring read match=0.65/exact=0.08 at the true shift,
    /// every guard refused it, and the session died (reseed ×3 → manual →
    /// unstitchable). Small per-column deltas must count as agreement.
    func testStitch_antialiasRephaseEveryStep_stillStitches() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(withAANoise(slice(page, atRow: 0), phase: 0, pageRow: 0)),
                       .appendedRows(viewportH))
        XCTAssertEqual(stitcher.append(withAANoise(slice(page, atRow: 112), phase: 1, pageRow: 112)),
                       .appendedRows(112),
                       "AA re-phase noise (≤6 gray levels) must not defeat the true alignment")
        XCTAssertEqual(stitcher.append(withAANoise(slice(page, atRow: 224), phase: 2, pageRow: 224)),
                       .appendedRows(112))
    }

    /// Gmail-class heavy re-render (measured on a real Gmail inbox capture):
    /// ~25% of overlap rows change beyond tolerance every step (cursor-hover
    /// band, row-tint flips, dense re-render), so the true shift scores only
    /// ~0.75 match / ~0.15 exact — under every standard bar — while every
    /// non-adjacent rival stays ≤0.35. In CONSTRAINED (auto) mode, where the
    /// commanded window already fences the candidates, a moderate-match peak
    /// with no comparable rival must be accepted (Lowe-style ratio test) or
    /// the whole session dies like the PingIdentity one did.
    func testAppendCommanded_moderateMatchUniquePeak_ratioAccepts() {
        let (frame1, frame2) = makeModerateMatchPair(shift: 150)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 180                       // page under-advances (150 real)
        XCTAssertEqual(stitcher.append(frame1), .appendedRows(churnViewportH))
        stitcher.commandedStepsAhead = 1
        XCTAssertEqual(stitcher.appendCommanded(frame2, advance: 180), .appendedRows(150),
                       "a uniquely dominant moderate-match peak must be accepted in auto mode")
    }

    /// Same heavy re-render, but the page advances exactly as commanded: the
    /// seam check finds ~0.75 match / ~0.15 exact at the commanded offset.
    /// It cannot take the standard fast path, but the bounded search must still
    /// accept it when its vote peak uniquely dominates every competing shift.
    func testAppendCommanded_moderateMatchAtCommandedSeam_accepts() {
        let (frame1, frame2) = makeModerateMatchPair(shift: 150)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 150
        XCTAssertEqual(stitcher.append(frame1), .appendedRows(churnViewportH))
        stitcher.commandedStepsAhead = 1
        XCTAssertEqual(stitcher.appendCommanded(frame2, advance: 150), .appendedRows(150),
                       "a moderate match at the commanded seam must be accepted in auto mode")
    }

    /// The auto session from the same real failure: blind commanded steps of
    /// 148px, but the modal's scroller actually advanced 112px per step, with
    /// the AA re-phase noise on every grab. The commanded seam misses (wrong
    /// distance), and the bounded fallback search must still accept the true
    /// 112 despite the noise.
    func testAppendCommanded_aaRephaseAndShortActualAdvance_alignsAtTrueShift() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 148
        XCTAssertEqual(stitcher.append(withAANoise(slice(page, atRow: 0), phase: 0, pageRow: 0)),
                       .appendedRows(viewportH))
        XCTAssertEqual(
            stitcher.appendCommanded(withAANoise(slice(page, atRow: 112), phase: 1, pageRow: 112), advance: 148),
            .appendedRows(112),
            "the short actual advance must be recovered by the fallback despite AA noise")
    }

    /// Google Docs-class sparse document: Chrome can scale a commanded wheel
    /// delta (76px requested, 56px observed). At the WRONG commanded shift,
    /// narrow text on a white page can still clear the churn-tolerant moderate
    /// match floor even though very few informative rows match exactly. The
    /// bounded candidate search must compare that weak commanded fit with the
    /// pixel-perfect true shift instead of duplicating 20 rows per step.
    func testAppendCommanded_sparseDocumentShortActualAdvance_usesTrueShift() {
        let page = makeSparsePage(height: 1200, lineWidth: 40)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 76
        XCTAssertEqual(stitcher.append(slice(page, atRow: 0)), .appendedRows(viewportH))

        XCTAssertEqual(stitcher.appendCommanded(slice(page, atRow: 56), advance: 76),
                       .appendedRows(56),
                       "a weak match at the command must not beat the exact true alignment")

        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, viewportH + 56)
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<(viewportH + 56))),
                      "wrong commanded alignment duplicated a strip in the document")
    }

    /// End-of-content recovery: the FINAL frame's overlap re-rendered (dynamic
    /// content — a chat re-laying-out its bottom), so the true alignment matches
    /// ~0.87 of rows within tolerance but almost none pixel-exact AND below the
    /// 0.9 dominance bar — the normal path rejects it (noOverlap) and the last
    /// tail would be lost. `appendFinalTail` accepts the highest match-ratio
    /// alignment so the final messages aren't dropped.
    func testAppendFinalTail_recoversLowExactGenuineAlignment() {
        let (frame1, frame2) = makeFinalTailPair(shift: 150)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(frame1), .appendedRows(churnViewportH))
        XCTAssertEqual(stitcher.append(frame2), .noOverlap,
                       "a re-rendered, sub-0.9-match overlap is rejected by the normal path")
        XCTAssertEqual(stitcher.appendFinalTail(frame2), .appendedRows(150),
                       "end-of-content recovery must append the final tail")
    }

    /// `appendFinalTail` must not invent an alignment when there genuinely is no
    /// overlap (a real fast-fling gap at the end) — it stays noOverlap.
    func testAppendFinalTail_noGenuineOverlap_staysNoOverlap() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 0))
        XCTAssertEqual(stitcher.appendFinalTail(slice(page, atRow: 900)), .noOverlap,
                       "no overlap (900 > viewportH) must not be force-stitched")
    }

    func testAppend_scrolledPastViewport_isNoOverlap() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 0))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 450)), .noOverlap)  // 450 > 400
    }

    /// A non-aligning append on a TALL frame must not pay an O(h²) brute-force
    /// shift scan. On a ~2800px Retina-scale frame the old exhaustive scan ran
    /// to completion 4× (~2s+); the signature-voting matcher resolves it in
    /// O(h). A generous 1s budget (vs ~2s old / ~tens of ms new) is a non-flaky
    /// regression guard against the quadratic scan returning.
    // MARK: - Constrained (commanded-step) search

    func testExpectedShift_windowComputedAroundCommand() {
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 200
        XCTAssertEqual(stitcher.expectedShiftWindow, 50...300,
                       "lower edge base/4 (partial advances), upper base + tolerance")
        stitcher.expectedShift = 20      // tolerance floor (+24)
        XCTAssertEqual(stitcher.expectedShiftWindow, 5...44)
        stitcher.expectedShift = nil
        XCTAssertNil(stitcher.expectedShiftWindow)
    }

    func testExpectedShift_acceptsCommandedAdvance_rejectsFarJump() {
        let page = makePage(height: 1600)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 150     // window 37...225
        _ = stitcher.append(slice(page, atRow: 0))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 150)), .appendedRows(150),
                       "the commanded advance stitches normally")
        XCTAssertEqual(stitcher.append(slice(page, atRow: 700)), .noOverlap,
                       "a jump far outside the commanded window is a transient, not a re-anchor")
    }

    func testAppendCommanded_pureStepsReproduceSource_lastPartialAligned() {
        let page = makePage(height: 1600)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 150
        _ = stitcher.append(slice(page, atRow: 0))
        // Healthy commanded steps append blindly at the command.
        for off in [150, 300, 450, 600] {
            XCTAssertEqual(stitcher.appendCommanded(slice(page, atRow: off), advance: 150),
                           .appendedRows(150))
        }
        // Bottom clamp: the page only advanced 80 — the single bounded
        // alignment must catch it instead of stamping 150.
        XCTAssertEqual(stitcher.appendCommanded(slice(page, atRow: 680), advance: 150),
                       .appendedRows(80))
        // Page stopped: identical frame is the finish signal.
        XCTAssertEqual(stitcher.appendCommanded(slice(page, atRow: 680), advance: 150),
                       .duplicate)
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, 680 + viewportH)
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<(680 + viewportH))),
                      "pure fixed-step reconstruction differs from source")
    }

    /// The YouTube wall (real capture, frame-dump verified): the page
    /// rescales the wheel (commanded 113 → actual 88 per step) AND
    /// re-renders ~17% of rows every step (thumbnail refreshes, antialias
    /// re-phasing), so the TRUE shift scores ~0.83 churn-tolerant — under
    /// the 0.85 permissive bar — while ~80% of rows stay PIXEL-EXACT. The
    /// bounded fallback must accept a standard-guard fit (match ≥ 0.6,
    /// exact ≥ 0.4) instead of freezing the capture at the first sub-0.85
    /// pair (observed live: stuck at 1049px while the page scrolled on).
    func testAppendCommanded_rescaledStepWithRowChurn_alignsAtTrueShift() {
        let page = makePage(height: 1600)
        func frame(atRow off: Int, seed: Int) -> CGImage {
            rerenderSomeRows(slice(page, atRow: off), seed: seed)
        }
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 113
        _ = stitcher.append(frame(atRow: 0, seed: 0))
        for (k, off) in [88, 176, 264, 352].enumerated() {
            XCTAssertEqual(stitcher.appendCommanded(frame(atRow: off, seed: k + 1), advance: 113),
                           .appendedRows(88),
                           "step to \(off) must glue at the true 88px advance")
        }
    }

    /// The real PingIdentity modal advanced 128px per step against a 168px
    /// command — a constant deficit, so the cheap commanded-seam check missed
    /// EVERY step and each append paid the full fallback search (measured
    /// 261ms optimized / 1.1s debug per step — the "scrolling is slow" bug).
    /// After a few CONSISTENT off-command accepts, the feedforward must
    /// retarget to the measured advance so the seam check hits again.
    func testAppendCommanded_consistentOffCommandAdvance_retargetsExpectedShift() {
        let page = makePage(height: 2400)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 168
        _ = stitcher.append(slice(page, atRow: 0))
        for off in [128, 256, 384, 512] {
            stitcher.commandedStepsAhead = 1
            XCTAssertEqual(
                stitcher.appendCommanded(slice(page, atRow: off), advance: stitcher.expectedShift!),
                .appendedRows(128), "step to \(off) must stitch at the true advance")
        }
        XCTAssertEqual(stitcher.expectedShift, 128,
                       "consistent off-command advances must retarget the feedforward")
    }

    /// A single stray off-command step (bottom clamp, scroll-pinned release
    /// jump) must NOT retarget — only a consistent run may.
    func testAppendCommanded_isolatedOffCommandStep_keepsFeedforward() {
        let page = makePage(height: 2400)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 150
        _ = stitcher.append(slice(page, atRow: 0))
        stitcher.commandedStepsAhead = 1
        XCTAssertEqual(stitcher.appendCommanded(slice(page, atRow: 100), advance: 150),
                       .appendedRows(100))   // one short step
        stitcher.commandedStepsAhead = 1
        XCTAssertEqual(stitcher.appendCommanded(slice(page, atRow: 250), advance: 150),
                       .appendedRows(150))   // back on command
        XCTAssertEqual(stitcher.expectedShift, 150,
                       "an isolated stray advance must not retarget the feedforward")
    }

    func testConstrained_drawOnlyNewRows_stillReproducesSource() {
        // Auto mode draws only each append's fresh rows (sticky-chrome
        // stamping fix) — the reconstruction must remain byte-exact.
        let page = makePage(height: 1600)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 150
        for off in [0, 150, 300, 450, 600] {
            XCTAssertNotEqual(stitcher.append(slice(page, atRow: off)), .noOverlap)
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, 600 + viewportH)
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<(600 + viewportH))),
                      "draw-only-new left a gap or misplaced band")
    }

    func testExpectedShift_windowTracksCommandedStepsAhead() {
        // After a miss the controller keeps count of injections since the
        // last successful stitch and widens the window accordingly, so the
        // accumulated advance re-locks instead of cascading noOverlap.
        let page = makePage(height: 1600)
        let stitcher = ScrollStitcher()
        stitcher.expectedShift = 150
        _ = stitcher.append(slice(page, atRow: 0))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 250)), .noOverlap,
                       "250 is outside 37...225 — a miss")
        stitcher.commandedStepsAhead = 2       // controller injected twice since match
        XCTAssertEqual(stitcher.expectedShiftWindow, 37...375)
        XCTAssertEqual(stitcher.append(slice(page, atRow: 250)), .appendedRows(250),
                       "the widened window re-locks onto the accumulated advance")
        stitcher.commandedStepsAhead = 1       // controller resets after success
        XCTAssertEqual(stitcher.expectedShiftWindow, 37...225)
    }

    func testAppend_tallNonAligningFrame_completesQuickly() {
        let w = 1600
        func bigFrame(h: Int, seed: Int) -> CGImage {
            let ctx = rgbaContext(width: w, height: h)
            for row in 0..<h {
                var x = UInt64(row &+ seed &* 1_000_003) &* 0x9E3779B97F4A7C15
                x ^= x >> 29
                ctx.setFillColor(CGColor(red: CGFloat((x >> 16) & 0xFF) / 255,
                                         green: CGFloat((x >> 8) & 0xFF) / 255,
                                         blue: CGFloat(x & 0xFF) / 255, alpha: 1))
                ctx.fill(CGRect(x: 0, y: h - row - 1, width: w, height: 1))
            }
            return ctx.makeImage()!
        }
        // Regression guard against the O(h²) brute-force shift scan returning.
        // A non-aligning append on a tall frame ran the exhaustive scan to
        // completion 4× — ~58s at h=2800; signature voting makes it O(h)
        // (~2.4s, dominated by the rowSignatures draw, not the search). The 20s
        // budget is deliberately wide so it stays green under heavy parallel
        // test load yet still trips on a return to quadratic (which is >25×).
        let h = 2800
        let stitcher = ScrollStitcher()
        _ = stitcher.append(bigFrame(h: h, seed: 1))
        let novel = bigFrame(h: h, seed: 2)
        let t0 = ProcessInfo.processInfo.systemUptime
        let result = stitcher.append(novel)
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        XCTAssertEqual(result, .noOverlap, "distinct content shares no alignment")
        XCTAssertLessThan(elapsed, 20.0,
                          "tall non-aligning append took \(elapsed)s — quadratic shift scan returned?")
    }

    func testAppend_noOverlapFrame_doesNotCorruptCanvas() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 0))
        _ = stitcher.append(slice(page, atRow: 450))   // skipped
        XCTAssertEqual(stitcher.append(slice(page, atRow: 200)), .appendedRows(200))
        XCTAssertEqual(stitcher.finish()?.height, 600)
    }

    func testStitchedHeight_tracksAppends() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        _ = stitcher.append(slice(page, atRow: 0))
        XCTAssertEqual(stitcher.stitchedHeight, viewportH)
        _ = stitcher.append(slice(page, atRow: 250))
        XCTAssertEqual(stitcher.stitchedHeight, viewportH + 250)
    }

    // MARK: - Caps

    func testAppend_pastMaxHeight_isCapReached() {
        var params = ScrollStitcher.Params()
        params.maxHeight = 500
        let page = makePage(height: 1600)
        let stitcher = ScrollStitcher(params: params)
        _ = stitcher.append(slice(page, atRow: 0))       // height 400
        XCTAssertEqual(stitcher.append(slice(page, atRow: 200)), .capReached)  // would be 600
        XCTAssertEqual(stitcher.stitchedHeight, viewportH, "cap rejects, doesn't append")
    }

    // MARK: - Sticky chrome

    func testStitch_stickyHeader_appearsOnceAtTop() {
        let headerH = 40
        let page = makePage(height: 1200)
        // Frames: constant header strip over scrolled content below it.
        func frame(atRow off: Int) -> CGImage {
            composite(header: solidStrip(height: headerH),
                      content: crop(page, rows: off..<(off + viewportH - headerH)))
        }
        let stitcher = ScrollStitcher()
        _ = stitcher.append(frame(atRow: 0))
        let r1 = stitcher.append(frame(atRow: 200))
        XCTAssertEqual(r1, .appendedRows(200))
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        // header (once) + content rows 0..<(200 + viewportH - headerH)
        let expected = composite(header: solidStrip(height: headerH),
                                 content: crop(page, rows: 0..<(200 + viewportH - headerH)))
        XCTAssertEqual(out.height, expected.height)
        XCTAssertTrue(imagesEqual(out, expected), "sticky header ghosted or content misaligned")
    }

    // MARK: - Real-world failure modes (chat-style content)

    /// Whitespace-dominant page (sparse text lines on a uniform background,
    /// like a chat log): long blank runs hash identically at every offset, so
    /// a naive match ratio can lock onto a tiny false dy. The stitch must
    /// still reproduce the source exactly.
    func testStitch_blankDominantPage_reproducesSource() {
        let page = makeSparsePage(height: 1200)
        let offsets = [0, 150, 320, 560, 800]
        let stitcher = ScrollStitcher()
        for off in offsets {
            let result = stitcher.append(slice(page, atRow: off))
            XCTAssertNotEqual(result, .noOverlap, "offset \(off) should align")
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, 800 + viewportH, "false alignment shortened the stitch")
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<(800 + viewportH))),
                      "stitched bytes differ from source")
    }

    /// A floating mid-viewport overlay (Jump-to-bottom pill, fixed in the
    /// viewport while content scrolls under it) must appear exactly once in
    /// the output — at its final position — not once per appended frame.
    func testStitch_floatingOverlay_appearsOnlyAtFinalPosition() {
        let pillRows = 300..<324
        let page = makePage(height: 1200)
        func frame(atRow off: Int) -> CGImage {
            stampPill(on: slice(page, atRow: off), rows: pillRows)
        }
        let stitcher = ScrollStitcher()
        for off in [0, 100, 200, 300] {
            XCTAssertNotEqual(stitcher.append(frame(atRow: off)), .noOverlap)
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        // Content rows 0..<700, pill only where the LAST frame put it.
        let lastBase = 300
        let expected = stampPill(
            on: crop(page, rows: 0..<700),
            rows: (lastBase + pillRows.lowerBound)..<(lastBase + pillRows.upperBound))
        XCTAssertEqual(out.height, 700)
        XCTAssertTrue(imagesEqual(out, expected),
                      "floating overlay ghosted into the scrolled content")
    }

    /// A TALL viewport-fixed overlay (Google Chat's Jump-to-bottom pill with
    /// its shadow, a hover toolbar) corrupts every row it covers — at its
    /// position in BOTH frames — which can exceed the whole-row mismatch
    /// allowance even though the overlay is narrow (a couple of sample
    /// columns). Alignment must tolerate a narrow vertical band of churn.
    func testStitch_tallNarrowViewportFixedOverlay_stillAligns() {
        let pillRows = 200..<264                       // 64 rows tall
        let page = makePage(height: 1200)
        func frame(atRow off: Int) -> CGImage {
            stampPill(on: slice(page, atRow: off), rows: pillRows, width: 40)  // ~2 sample columns
        }
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(frame(atRow: 0)), .appendedRows(viewportH))
        XCTAssertEqual(stitcher.append(frame(atRow: 100)), .appendedRows(100),
                       "narrow fixed overlay must not defeat alignment")
        XCTAssertEqual(stitcher.append(frame(atRow: 200)), .appendedRows(100))
        XCTAssertEqual(stitcher.stitchedHeight, 600)
    }

    /// NARROW chat bubbles (text spanning only a couple of sample columns on
    /// a white page) must not false-match blank rows under the churn-column
    /// tolerance: a text row differing in ≤ maxChurn columns would
    /// otherwise "match" anything, letting a tiny wrong shift win and stamp
    /// repeated/blended content. The stitch must reproduce the source.
    func testStitch_narrowBubbleSparsePage_reproducesSource() {
        let page = makeSparsePage(height: 1200, lineWidth: 40)   // ~2 sample columns
        let offsets = [0, 150, 320, 560]
        let stitcher = ScrollStitcher()
        for off in offsets {
            XCTAssertNotEqual(stitcher.append(slice(page, atRow: off)), .noOverlap,
                              "offset \(off) should align")
        }
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, 560 + viewportH, "false alignment distorted the stitch")
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<(560 + viewportH))),
                      "stitched bytes differ from source (misaligned append)")
    }

    /// A fast fling can move content more than a viewport between samples —
    /// that frame has no overlap with the last appended frame and is lost.
    /// The session must RECOVER anywhere in captured content: alignment is
    /// against the last APPENDED frame, so returning to a part of the canvas
    /// far from it (here: the top, while the frontier is 900 rows below)
    /// must re-anchor against the canvas, not fail forever.
    func testStitch_gapThenReturnFarFromFrontier_reanchorsAndResumes() {
        let page = makePage(height: 2400)
        let stitcher = ScrollStitcher()
        for off in [0, 300, 600, 900] {
            XCTAssertEqual(stitcher.append(slice(page, atRow: off)),
                           .appendedRows(off == 0 ? viewportH : 300))
        }
        // Fling: 900 → 1900 moves > viewportH — unbridgeable gap, frame lost.
        XCTAssertEqual(stitcher.append(slice(page, atRow: 1900)), .noOverlap)
        // Return near the TOP of the canvas: 800 rows from the last appended
        // frame (no direct overlap with it), but inside captured content.
        XCTAssertEqual(stitcher.append(slice(page, atRow: 100)), .appendedRows(0),
                       "returning into captured content must re-anchor")
        // Scrolling resumes from the re-anchored position and can extend the
        // frontier again.
        XCTAssertEqual(stitcher.append(slice(page, atRow: 1100)), .appendedRows(200))
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, 1500)
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<1500)),
                      "re-anchored stitch differs from source")
    }

    // MARK: - Bidirectional

    /// Scrolling UP extends the capture upward: descending offsets must
    /// reproduce the full span, not just the first viewport.
    func testStitch_scrollUp_prependsContent() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(slice(page, atRow: 400)), .appendedRows(viewportH))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 250)), .appendedRows(150))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 100)), .appendedRows(150))
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, 700)
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 100..<800)),
                      "upward prepend did not reproduce the source span")
    }

    /// Wandering: down, up past the start, back down through captured
    /// territory (delta 0), then past the frontier. Byte-exact throughout.
    func testStitch_mixedDirections_reconstructsSpan() {
        let page = makePage(height: 1200)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(slice(page, atRow: 300)), .appendedRows(viewportH))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 150)), .appendedRows(150))
        XCTAssertEqual(stitcher.append(slice(page, atRow: 0)), .appendedRows(150))
        // Back down through already-captured content: aligned, adds nothing.
        XCTAssertEqual(stitcher.append(slice(page, atRow: 200)), .appendedRows(0))
        // Past the old frontier (700): extends by 150.
        XCTAssertEqual(stitcher.append(slice(page, atRow: 450)), .appendedRows(150))
        guard let out = stitcher.finish() else { return XCTFail("no output") }
        XCTAssertEqual(out.height, 850)
        XCTAssertTrue(imagesEqual(out, crop(page, rows: 0..<850)),
                      "mixed-direction stitch differs from source")
    }

    // MARK: - RowSig SIMD signature

    /// The row signature must hold more than the legacy 16 samples and count
    /// per-column disagreement (masked and unmasked) over all used lanes.
    func testRowSig_churnCounts_supportMoreThan16Columns() {
        var a = SIMD64<UInt8>(), b = SIMD64<UInt8>()
        for k in 0..<64 { a[k] = UInt8(k); b[k] = UInt8(k) }
        b[40] = 200                                   // differ in a lane past the old 16-lane limit
        let sa = ScrollStitcher.RowSig(lanes: a)
        let sb = ScrollStitcher.RowSig(lanes: b)
        XCTAssertEqual(sa.churnColumns(vs: sb), 1)
        var mask = SIMD64<UInt8>(repeating: 0xFF); mask[40] = 0
        XCTAssertEqual(sa.churnColumns(vs: sb, mask: mask), 0, "masking the only differing lane => no churn")
    }

    // MARK: - Width-scaled sampling

    func testRowSig_sampleCountScalesWithWidth() {
        let p = ScrollStitcher.Params()
        XCTAssertEqual(ScrollStitcher.sampleCount(forWidth: 300, params: p), 16, "narrow: floor")
        XCTAssertEqual(ScrollStitcher.sampleCount(forWidth: 512, params: p), 16, "at floor boundary")
        XCTAssertEqual(ScrollStitcher.sampleCount(forWidth: 1600, params: p), 50)
        XCTAssertEqual(ScrollStitcher.sampleCount(forWidth: 2940, params: p), 64, "wide: capped")
    }

    /// A WIDE page whose distinctive content sits on a fine column pitch that
    /// the legacy 16-sample grid steps over (sampling only the gaps) while the
    /// width-scaled grid lands on it. With 16 samples consecutive frames look
    /// identical and nothing stitches; width-scaled sampling aligns and extends.
    func testStitch_wideFineContent_undersampledAt16_stitchesWhenScaled() {
        let page = makeWidePage(height: 1200)
        // Forced to the legacy 16-sample density: undersampled, no extension.
        var capped = ScrollStitcher.Params(); capped.minSamples = 16; capped.maxSamples = 16
        let s16 = ScrollStitcher(params: capped)
        XCTAssertEqual(s16.append(wideSlice(page, atRow: 0)), .appendedRows(wideViewportH))
        XCTAssertNotEqual(s16.append(wideSlice(page, atRow: 150)), .appendedRows(150),
                          "16 samples step over the fine content — no real extension")
        XCTAssertEqual(s16.stitchedHeight, wideViewportH, "nothing beyond the seed")
        // Default width-scaled density: aligns and extends.
        let s = ScrollStitcher()
        for off in [0, 150, 320] {
            XCTAssertNotEqual(s.append(wideSlice(page, atRow: off)), .noOverlap, "offset \(off)")
        }
        XCTAssertEqual(s.stitchedHeight, 320 + wideViewportH)
    }

    // MARK: - Fixtures

    private let churnViewportH = 400
    /// Two 300px-wide frames overlapping by `shift`. Each source row is a
    /// distinct solid gray; the second frame matches the first within the churn
    /// tolerance on every overlap row, but ~55% of those rows have a single
    /// sampled column perturbed (a 1-column difference, ≤ maxChurn), so they are
    /// NOT pixel-exact — driving the true-shift exact-match fraction to ~0.45.
    /// Seed + scrolled frame whose overlap re-rendered HEAVILY (Gmail-class):
    /// ~25% of overlap rows fully repainted (hover band, row-tint flips),
    /// ~60% match with a 1-column perturbation, ~15% pixel-exact — so the
    /// true shift scores ~0.75 match / ~0.15 exact: below the permissive
    /// (0.85), standard-exact (0.40) and dominance (0.90) bars, yet uniquely
    /// dominant (hashed grays give wrong shifts ~no score).
    private func makeModerateMatchPair(shift: Int) -> (CGImage, CGImage) {
        func gray(_ r: Int) -> UInt8 {
            var h = UInt64(truncatingIfNeeded: r) &* 0x9E3779B97F4A7C15
            h ^= h >> 29
            return UInt8(truncatingIfNeeded: h >> 32)
        }
        func bucket(_ r: Int) -> Int { Int((UInt32(truncatingIfNeeded: r) &* 2654435761) >> 24) & 0xFF }
        let w = 300, h = churnViewportH
        func make(top: Int, rerender: Bool) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
            for row in 0..<h {
                let g = gray(top + row)
                for x in 0..<w { data[row * ctx.bytesPerRow + x] = g }
                guard rerender, row < h - shift else { continue }
                let b = bucket(top + row)
                if b < 64 {                                          // ~25% fully repainted → mismatch
                    for x in 0..<w { data[row * ctx.bytesPerRow + x] = g &+ 128 }
                } else if b < 217 {                                  // ~60% 1-col perturb → match, not exact
                    data[row * ctx.bytesPerRow + 159] = g &+ 80
                }                                                    // else ~15% exact (vote feed)
            }
            return ctx.makeImage()!
        }
        return (make(top: 0, rerender: false), make(top: shift, rerender: true))
    }

    private func makeExactBoundaryPair(shift: Int, perturbMod: Int = 11) -> (CGImage, CGImage) {
        func gray(_ r: Int) -> UInt8 { UInt8((r &* 61 &+ 7) & 0xFF) }   // distinct per row
        func make(top: Int, perturb: Bool) -> CGImage {
            let w = 300, h = churnViewportH
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
            for row in 0..<h {
                let g = gray(top + row)
                for x in 0..<w { data[row * ctx.bytesPerRow + x] = g }
                // x=159 is sampled column 8 of 16 for a 300px frame; perturbing
                // it on `perturbMod`/20 of rows makes them match (churn 1) but
                // not exact, driving the true-shift exact fraction below 1.
                if perturb && row % 20 < perturbMod { data[row * ctx.bytesPerRow + 159] = g &+ 80 }
            }
            return ctx.makeImage()!
        }
        return (make(top: 0, perturb: false), make(top: shift, perturb: true))
    }

    /// Seed + a scrolled frame whose overlap RE-RENDERED: ~7/8 of overlap rows
    /// match within churn but with a 1-column perturbation (not pixel-exact), and
    /// ~1/8 are fully repainted (a multi-column change → genuine mismatch), so the
    /// true shift scores ~0.87 match / ~0 exact — rejected by the normal path
    /// (exact < 0.40 and match < 0.90) yet recoverable by `appendFinalTail`.
    private func makeFinalTailPair(shift: Int) -> (CGImage, CGImage) {
        // Hashed (non-linear) per-row gray so values don't repeat on a fixed
        // period — a linear mod-256 gray would create a false wrap-alignment at
        // (256 - shift).
        func gray(_ r: Int) -> UInt8 {
            var h = UInt64(truncatingIfNeeded: r) &* 0x9E3779B97F4A7C15
            h ^= h >> 29
            return UInt8(truncatingIfNeeded: h >> 32)
        }
        // Pseudo-random per-row bucket (non-periodic, so it can't form a false
        // shift): ~12% mismatch, ~58% perturbed-match, ~30% exact.
        func bucket(_ r: Int) -> Int { Int((UInt32(truncatingIfNeeded: r) &* 2654435761) >> 24) & 0xFF }
        let w = 300, h = churnViewportH
        func make(top: Int, rerender: Bool) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
            for row in 0..<h {
                let g = gray(top + row)
                for x in 0..<w { data[row * ctx.bytesPerRow + x] = g }
                guard rerender, row < h - shift else { continue }   // only the overlap re-renders
                let b = bucket(top + row)
                if b < 32 {                                          // ~12% fully repainted → mismatch
                    for x in 0..<w { data[row * ctx.bytesPerRow + x] = g &+ 128 }
                } else if b < 180 {                                  // ~58% 1-col perturb → match, not exact
                    data[row * ctx.bytesPerRow + 159] = g &+ 80
                }                                                    // else ~30% exact (gives the true shift its votes)
            }
            return ctx.makeImage()!
        }
        return (make(top: 0, rerender: false), make(top: shift, rerender: true))
    }

    /// Every row gets a distinct deterministic color (hash of the row index),
    /// so any two different rows differ and matching is unambiguous.
    /// `copying` duplicates a row range elsewhere (repeated page content).
    private func makePage(height: Int, copying: Range<Int>? = nil, to dest: Int = 0) -> CGImage {
        let ctx = rgbaContext(width: viewportW, height: height)
        func paint(_ row: Int, asRow source: Int) {
            var h = UInt64(source) &* 0x9E3779B97F4A7C15
            h ^= h >> 29
            let r = CGFloat((h >> 16) & 0xFF) / 255
            let g = CGFloat((h >> 8) & 0xFF) / 255
            let b = CGFloat(h & 0xFF) / 255
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            // CGContext y is bottom-up; row index is top-down.
            ctx.fill(CGRect(x: 0, y: height - row - 1, width: viewportW, height: 1))
        }
        for row in 0..<height { paint(row, asRow: row) }
        if let copying {
            for (i, src) in copying.enumerated() { paint(dest + i, asRow: src) }
        }
        return ctx.makeImage()!
    }

    /// Mostly-white page with a 4-row distinct-colored text line every 120
    /// rows (chat-log shape: long identical blank runs between content).
    /// `lineWidth` narrows the lines (left-aligned chat bubbles touch only a
    /// few sample columns); the default spans the full viewport.
    private func makeSparsePage(height: Int, lineWidth: Int? = nil) -> CGImage {
        let ctx = rgbaContext(width: viewportW, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: viewportW, height: height))
        let w = lineWidth ?? viewportW
        var row = 60
        while row + 4 <= height {
            for line in row..<(row + 4) {
                var h = UInt64(line) &* 0x9E3779B97F4A7C15
                h ^= h >> 29
                ctx.setFillColor(CGColor(red: CGFloat((h >> 16) & 0xFF) / 255,
                                         green: CGFloat((h >> 8) & 0xFF) / 255,
                                         blue: CGFloat(h & 0xFF) / 255, alpha: 1))
                ctx.fill(CGRect(x: 20, y: height - line - 1, width: w, height: 1))
            }
            row += 120
        }
        return ctx.makeImage()!
    }

    /// A copy of `image` with a horizontally centered "pill" rect stamped
    /// over `rows` (image pixel rows, top-left origin).
    private func stampPill(on image: CGImage, rows: Range<Int>, width: Int = 100) -> CGImage {
        let w = image.width, h = image.height
        let ctx = rgbaContext(width: w, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: (w - width) / 2, y: h - rows.upperBound,
                        width: width, height: rows.count))
        return ctx.makeImage()!
    }

    /// Copy of `image` with every 6th row filled with a seed-dependent color
    /// across the full width — a stand-in for per-step content re-rendering
    /// (thumbnail refreshes, antialias re-phasing) that corrupts ~17% of
    /// rows beyond the churn tolerance while the rest stay pixel-exact.
    private func rerenderSomeRows(_ image: CGImage, seed: Int) -> CGImage {
        let w = image.width, h = image.height
        let ctx = rgbaContext(width: w, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let shade = CGFloat(30 + (seed * 37) % 200) / 255
        ctx.setFillColor(CGColor(red: shade, green: shade, blue: 1 - shade, alpha: 1))
        for row in stride(from: 0, to: h, by: 6) {
            ctx.fill(CGRect(x: 0, y: h - row - 1, width: w, height: 1))
        }
        return ctx.makeImage()!
    }

    /// Copy of `image` with antialiasing re-phase noise, modeled on the real
    /// PingIdentity frame dump: per PAGE row (`pageRow` = the slice's page
    /// offset), ~37% of columns render stably (byte-exact at any scroll
    /// position — the anchors; 91% of all pixels were identical in the real
    /// capture) while the rest shift by a `phase`-dependent 2–6 gray levels
    /// (glyph edges re-rasterizing). Every 10th page row renders fully
    /// byte-exact — in the real capture ~8% of rows survived exactly, and
    /// those page-anchored rows feed the byte-exact vote index. The layout
    /// itself translates by an exact integer offset.
    private func withAANoise(_ image: CGImage, phase: Int, pageRow: Int) -> CGImage {
        let w = image.width, h = image.height
        let ctx = rgbaContext(width: w, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { fatalError("no bitmap data") }
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        for row in 0..<h where (row &+ pageRow) % 10 != 0 {
            for col in 0..<w {
                var hc = UInt64(truncatingIfNeeded: col &* 31 &+ row &+ pageRow)
                    &* 0x9E3779B97F4A7C15
                hc ^= hc >> 33
                guard hc % 8 >= 3 else { continue }   // stable column → anchor
                let base = row * ctx.bytesPerRow + col * 4
                let delta = UInt8(2 + ((hc >> 8) &+ UInt64(phase)) % 5)
                for ch in 0..<3 {
                    px[base + ch] = px[base + ch] > 255 - delta ? 255 : px[base + ch] &+ delta
                }
            }
        }
        return ctx.makeImage()!
    }

    private func solidStrip(height: Int) -> CGImage {
        let ctx = rgbaContext(width: viewportW, height: height)
        ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: viewportW, height: height))
        return ctx.makeImage()!
    }

    /// Viewport-sized slice of the page starting at `row` (top-left origin).
    /// Copy of `image` with `rows` filled solid — a stand-in for an animated
    /// element changing between two samples of the same scroll position.
    private func withBand(_ image: CGImage, rows: Range<Int>) -> CGImage {
        let h = image.height
        let ctx = rgbaContext(width: image.width, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: h))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1))
        // CGContext y is bottom-up; row indices are top-down.
        ctx.fill(CGRect(x: 0, y: h - rows.upperBound,
                        width: image.width, height: rows.count))
        return ctx.makeImage()!
    }

    /// Copy of `image` with a STRUCTURED chrome band over `rows` — distinct
    /// per-row colors like a real masthead (search box, buttons), so the
    /// stitcher's chrome lock (which refuses structureless blank runs)
    /// engages. `variant` produces a visibly different band (scroll shadow,
    /// animating chrome).
    private func withHeader(_ image: CGImage, rows: Range<Int>, variant: Int = 0) -> CGImage {
        let h = image.height
        let ctx = rgbaContext(width: image.width, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: h))
        for row in rows {
            var hash = UInt64(row &+ 7919 &* (variant &+ 3)) &* 0xff51afd7ed558ccd
            hash ^= hash >> 31
            let r = CGFloat((hash >> 16) & 0xFF) / 255
            let g = CGFloat((hash >> 8) & 0xFF) / 255
            let b = CGFloat(hash & 0xFF) / 255
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h - row - 1, width: image.width, height: 1))
        }
        return ctx.makeImage()!
    }

    private func slice(_ page: CGImage, atRow row: Int) -> CGImage {
        crop(page, rows: row..<(row + viewportH))
    }

    /// Copy of `image` with every `everyNth`-th row in `rows` repainted a new
    /// distinct color — models a photographic/lazy-loading page where a
    /// fraction of the overlap re-renders between consecutive frames (images
    /// streaming in, photo resampling), so the true alignment matches well
    /// below 100% of rows while every other shift matches ~none.
    private func reRenderRows(_ image: CGImage, rows: Range<Int>, everyNth: Int) -> CGImage {
        let h = image.height
        let ctx = rgbaContext(width: image.width, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: h))
        for row in rows where (row - rows.lowerBound) % everyNth == 0 {
            var hash = UInt64(row &+ 1) &* 0xD1B54A32D192ED03
            hash ^= hash >> 33
            ctx.setFillColor(CGColor(red: CGFloat((hash >> 16) & 0xFF) / 255,
                                     green: CGFloat((hash >> 8) & 0xFF) / 255,
                                     blue: CGFloat(hash & 0xFF) / 255, alpha: 1))
            // CGContext y is bottom-up; row indices are top-down.
            ctx.fill(CGRect(x: 0, y: h - row - 1, width: image.width, height: 1))
        }
        return ctx.makeImage()!
    }

    /// A frame with FIXED left + right side columns (`sideWidth` px each) of
    /// structured, per-row-distinct chrome that is identical in every frame,
    /// and a center column showing `centerPage` scrolled to `off`. Models a
    /// docs page: fixed sidebar + TOC, scrolling article in the middle.
    private func sidebarFrame(_ centerPage: CGImage, atRow off: Int, sideWidth: Int) -> CGImage {
        let ctx = rgbaContext(width: viewportW, height: viewportH)
        // Fixed side chrome — distinct per ROW (so it has structure) but the
        // SAME in every frame (it does not scroll).
        for row in 0..<viewportH {
            var h = UInt64(row &+ 104729) &* 0xff51afd7ed558ccd
            h ^= h >> 31
            ctx.setFillColor(CGColor(red: CGFloat((h >> 16) & 0xFF) / 255,
                                     green: CGFloat((h >> 8) & 0xFF) / 255,
                                     blue: CGFloat(h & 0xFF) / 255, alpha: 1))
            let y = viewportH - row - 1
            ctx.fill(CGRect(x: 0, y: y, width: sideWidth, height: 1))
            ctx.fill(CGRect(x: viewportW - sideWidth, y: y, width: sideWidth, height: 1))
        }
        // Scrolling center column, clipped to the middle band.
        let center = crop(centerPage, rows: off..<(off + viewportH))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: sideWidth, y: 0,
                            width: viewportW - 2 * sideWidth, height: viewportH))
        ctx.draw(center, in: CGRect(x: 0, y: 0, width: viewportW, height: viewportH))
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    /// Like `sidebarFrame`, but the scrolling center content sits only in
    /// `[sideWidth, textRight]`; the rest of the center band is blank white —
    /// models an article whose content reaches different widths down the page.
    private func sidebarRaggedFrame(_ centerPage: CGImage, atRow off: Int,
                                    sideWidth: Int, textRight: Int) -> CGImage {
        let ctx = rgbaContext(width: viewportW, height: viewportH)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: viewportW, height: viewportH))
        for row in 0..<viewportH {
            var h = UInt64(row &+ 104729) &* 0xff51afd7ed558ccd
            h ^= h >> 31
            ctx.setFillColor(CGColor(red: CGFloat((h >> 16) & 0xFF) / 255,
                                     green: CGFloat((h >> 8) & 0xFF) / 255,
                                     blue: CGFloat(h & 0xFF) / 255, alpha: 1))
            let y = viewportH - row - 1
            ctx.fill(CGRect(x: 0, y: y, width: sideWidth, height: 1))
            ctx.fill(CGRect(x: viewportW - sideWidth, y: y, width: sideWidth, height: 1))
        }
        let center = crop(centerPage, rows: off..<(off + viewportH))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: sideWidth, y: 0, width: textRight - sideWidth, height: viewportH))
        ctx.draw(center, in: CGRect(x: 0, y: 0, width: viewportW, height: viewportH))
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    /// Terminal-shaped frame: content in the left columns, and a mostly-blank
    /// right margin that only the longest lines' endings protrude into. The
    /// margin content SCROLLS with the page (it is page content, not chrome),
    /// but it barely changes between frames and has structure in only ~3% of
    /// rows — the measured shape of the falsely-blanked iTerm capture.
    private func terminalMarginFrame(_ page: CGImage, atRow off: Int, marginWidth: Int) -> CGImage {
        let ctx = rgbaContext(width: viewportW, height: viewportH)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: viewportW, height: viewportH))
        let content = crop(page, rows: off..<(off + viewportH))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: viewportW - marginWidth, height: viewportH))
        ctx.draw(content, in: CGRect(x: 0, y: 0, width: viewportW, height: viewportH))
        ctx.restoreGState()
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.4, alpha: 1))
        // Offset so the SEED's row 0 is background, not a mark — the structure
        // test baselines against row 0 (a mark there would make every
        // background row count as "structured", the opposite of this shape).
        for row in 0..<viewportH where (row + off + 50) % 97 < 3 {
            ctx.fill(CGRect(x: viewportW - marginWidth, y: viewportH - row - 1,
                            width: marginWidth, height: 1))
        }
        return ctx.makeImage()!
    }

    private func crop(_ image: CGImage, rows: Range<Int>) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: rows.lowerBound,
                                  width: image.width, height: rows.count))!
    }

    /// Header strip stacked above content (both full viewport width).
    private func composite(header: CGImage, content: CGImage) -> CGImage {
        let h = header.height + content.height
        let ctx = rgbaContext(width: viewportW, height: h)
        // CG draws bottom-up: content at bottom, header on top.
        ctx.draw(content, in: CGRect(x: 0, y: 0, width: viewportW, height: content.height))
        ctx.draw(header, in: CGRect(x: 0, y: content.height, width: viewportW, height: header.height))
        return ctx.makeImage()!
    }

    private func rgbaContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// A 1600px-wide page. Each row is solid white except 1px vertical stripes
    /// at x = 16, 48, 80, … (pitch 32), each row's stripes colored by a hash of
    /// the row index. The width-scaled grid for 1600px samples exactly those
    /// columns (16·(2k+1)); the legacy 16-sample grid samples 50·(2k+1) =
    /// 50,150,… which all fall on white — so only dense sampling sees content.
    private let wideW = 1600
    private let wideViewportH = 400
    private func makeWidePage(height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: wideW, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * wideW, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: wideW, height: height))
        for row in 0..<height {
            var h = UInt64(row) &* 0x9E3779B97F4A7C15; h ^= h >> 29
            ctx.setFillColor(CGColor(red: CGFloat((h >> 16) & 0xFF) / 255,
                                     green: CGFloat((h >> 8) & 0xFF) / 255,
                                     blue: CGFloat(h & 0xFF) / 255, alpha: 1))
            var x = 16
            while x < wideW {
                ctx.fill(CGRect(x: x, y: height - row - 1, width: 1, height: 1))
                x += 32
            }
        }
        return ctx.makeImage()!
    }
    private func wideSlice(_ page: CGImage, atRow row: Int) -> CGImage {
        page.cropping(to: CGRect(x: 0, y: row, width: wideW, height: wideViewportH))!
    }

    private func imagesEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        return rgbaBytes(a) == rgbaBytes(b)
    }

    private func rgbaBytes(_ img: CGImage) -> [UInt8] {
        let ctx = rgbaContext(width: img.width, height: img.height)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let count = ctx.bytesPerRow * img.height
        let raw = ctx.data!.bindMemory(to: UInt8.self, capacity: count)
        return Array(UnsafeBufferPointer(start: raw, count: count))
    }

    private func isAllWhite(_ img: CGImage) -> Bool {
        let b = rgbaBytes(img)
        var i = 0
        while i < b.count {
            if b[i] < 250 || b[i + 1] < 250 || b[i + 2] < 250 { return false }
            i += 4
        }
        return true
    }

    private func hasNonWhite(_ img: CGImage) -> Bool { !isAllWhite(img) }
}
