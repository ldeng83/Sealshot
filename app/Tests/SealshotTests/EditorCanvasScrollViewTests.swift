import XCTest
@testable import Sealshot

@MainActor
final class EditorCanvasScrollViewTests: XCTestCase {

    func test_clampZoom_manualAllowsAbove100UpToCeiling() {
        // Manual zoom (buttons / typed input) is no longer capped at 100% —
        // 100% is just the auto-fit default. clampZoom permits values above
        // 1.0 up to the safety ceiling (manualMaxZoom).
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.9), 0.9, accuracy: 0.001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(1.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(1.5), 1.5, accuracy: 0.001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(4.0), 4.0, accuracy: 0.001)
        XCTAssertEqual(
            EditorCanvasScrollView.clampZoom(100.0),
            EditorCanvasScrollView.manualMaxZoom,
            accuracy: 0.001
        )
    }

    // MARK: - Settling an animated glide

    // An animated `setMagnification` sets the MODEL property to the target at
    // once while Core Animation animates the APPLIED value, and the applied
    // value can stop a hair short: a trace of 70% -> 100% ended with
    // `magnification == 1.0000` while the canvas layer sat at 0.9907. AppKit
    // keeps the layer consistent with the applied value, so it reverted every
    // correction we wrote — the capture really was being resampled at 99%.
    // Re-assigning the target is a no-op precisely because the model already
    // equals it, so settling has to write a DIFFERENT value first.

    func test_glideSettleNudge_differsEnoughToNotBeANoOp() {
        // Must clear AppKit's own no-change threshold, or the write does nothing.
        for z in [CGFloat(1.0), 0.5, 2.0, 0.64] {
            let nudge = EditorCanvasScrollView.glideSettleNudge(for: z)
            XCTAssertGreaterThan(
                abs(nudge - z), 0.0005,
                "nudge for \(z) is too close to the target to force a change"
            )
        }
    }

    func test_glideSettleNudge_staysInsideLegalMagnificationRange() {
        // The nudge is assigned to `magnification` directly, so an out-of-range
        // value would be clamped by AppKit — landing somewhere we did not mean.
        for z in [EditorCanvasScrollView.minZoom, EditorCanvasScrollView.manualMaxZoom] {
            let nudge = EditorCanvasScrollView.glideSettleNudge(for: z)
            XCTAssertGreaterThanOrEqual(nudge, EditorCanvasScrollView.minZoom)
            XCTAssertLessThanOrEqual(nudge, EditorCanvasScrollView.manualMaxZoom)
        }
    }

    func test_glideSettleNudge_survivesClampZoomUnitySnap() {
        // clampZoom snaps anything within `unitySnapTolerance` of 1.0 TO 1.0.
        // If the nudge for 100% were routed through it, it would collapse back
        // onto the target and the no-op returns. Guards the ordering.
        let nudge = EditorCanvasScrollView.glideSettleNudge(for: 1.0)
        XCTAssertNotEqual(nudge, 1.0, accuracy: 0.0001)
    }

    func test_fitZoom_smallImageNotUpscaled() {
        // A small image (smaller than the viewport) must fit at most 100% —
        // never blown up past native pixels.
        let z = EditorCanvasScrollView.fitZoom(
            imageSize: CGSize(width: 200, height: 150),
            viewportSize: CGSize(width: 1000, height: 800),
            inset: 0
        )
        XCTAssertEqual(z, 1.0, accuracy: 0.001)
    }

    func test_clampZoomOut_floorsAt10() {
        // The zoom slider goes down to 10%, so the manual floor is 0.10.
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.3), 0.3, accuracy: 0.001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.10), 0.10, accuracy: 0.001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.05), 0.10, accuracy: 0.001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.0), 0.10, accuracy: 0.001)
    }

    func test_fitZoom_landscapeImage() {
        // 2000x1000 image into 1000x800 viewport => limited by width:
        // 1000 / 2000 = 0.5
        let z = EditorCanvasScrollView.fitZoom(
            imageSize: CGSize(width: 2000, height: 1000),
            viewportSize: CGSize(width: 1000, height: 800),
            inset: 0
        )
        XCTAssertEqual(z, 0.5, accuracy: 0.001)
    }

    func test_fitZoom_portraitImage() {
        // 500x1000 image into 1000x800 viewport => limited by height:
        // 800 / 1000 = 0.8
        let z = EditorCanvasScrollView.fitZoom(
            imageSize: CGSize(width: 500, height: 1000),
            viewportSize: CGSize(width: 1000, height: 800),
            inset: 0
        )
        XCTAssertEqual(z, 0.8, accuracy: 0.001)
    }

    func test_fitWidthZoom_upscalesSmallImage() {
        // Fit-width is an explicit action: a low-res image narrower than the
        // viewport upscales to span the full width (unlike whole-image fit,
        // which caps at 100%). ≈ 1000 / 200 = 5.0 (minus the sub-pixel safety).
        let z = EditorCanvasScrollView.fitWidthZoom(
            imageWidth: 200, viewportWidth: 1000, padding: 0)
        XCTAssertEqual(z, 5.0, accuracy: 0.01)
    }

    func test_fitWidth_reservesScrollerWhenTallerThanViewport() {
        // A tall image: fit-to-width overflows vertically, so a legacy vertical
        // scroller will claim width. Reserve it so the zoomed document
        // ((img + 2·pad)·z — the padding scales with magnification) leaves
        // exactly that much room — the fit settles in one click.
        let z = EditorCanvasScrollView.fitWidthZoom(
            imageSize: CGSize(width: 1000, height: 2000),
            viewportSize: CGSize(width: 800, height: 600),
            padding: 16, scrollerWidth: 15)
        let documentWidth = (1000 + 32) * z
        XCTAssertLessThanOrEqual(documentWidth, 800 - 15, "must not overflow → no H scrollbar")
        XCTAssertEqual(documentWidth, 800 - 15, accuracy: 1.0)
    }

    func test_fitWidth_noReservationWhenFitsVertically() {
        // A short image: no vertical overflow → no scroller → no reservation.
        let z = EditorCanvasScrollView.fitWidthZoom(
            imageSize: CGSize(width: 1000, height: 100),
            viewportSize: CGSize(width: 800, height: 600),
            padding: 16, scrollerWidth: 15)
        let documentWidth = (1000 + 32) * z
        XCTAssertLessThanOrEqual(documentWidth, 800)
        XCTAssertEqual(documentWidth, 800, accuracy: 1.0)
    }

    func test_fitWidth_overlayScrollerReservesNothing() {
        // Overlay scrollers float over content (width 0): even a tall image
        // reserves nothing, so the document may fill the viewport exactly.
        let z = EditorCanvasScrollView.fitWidthZoom(
            imageSize: CGSize(width: 1000, height: 2000),
            viewportSize: CGSize(width: 800, height: 600),
            padding: 16, scrollerWidth: 0)
        let documentWidth = (1000 + 32) * z
        XCTAssertLessThanOrEqual(documentWidth, 800)
        XCTAssertEqual(documentWidth, 800, accuracy: 1.0)
    }

    func test_fitWidth_upscaledImageDoesNotOverflow() {
        // THE tiny-scrollbar regression: fitting a NARROW image upscales, and
        // the padding border scales with the zoom. The old math budgeted a
        // fixed 32pt, so the document overflowed by 2·pad·(z−1) — a scrollbar
        // that scrolled a few pixels. The document must never exceed the
        // viewport width.
        let z = EditorCanvasScrollView.fitWidthZoom(
            imageSize: CGSize(width: 400, height: 300),
            viewportSize: CGSize(width: 1000, height: 800),
            padding: 16, scrollerWidth: 15)
        XCTAssertGreaterThan(z, 1.0, "narrow image must upscale")
        let documentWidth = (400 + 32) * z
        XCTAssertLessThanOrEqual(documentWidth, 1000, "no horizontal overflow at fit-width")
    }

    func test_fitHeight_upscaledImageDoesNotOverflow() {
        let z = EditorCanvasScrollView.fitHeightZoom(
            imageSize: CGSize(width: 300, height: 400),
            viewportSize: CGSize(width: 800, height: 1000),
            padding: 16, scrollerWidth: 15)
        XCTAssertGreaterThan(z, 1.0, "short image must upscale")
        let documentHeight = (400 + 32) * z
        XCTAssertLessThanOrEqual(documentHeight, 1000, "no vertical overflow at fit-height")
    }

    func test_fitHeight_reservesScrollerWhenWiderThanViewport() {
        // A wide image: fit-to-height overflows horizontally → reserve the
        // horizontal scroller so it settles in one click.
        let z = EditorCanvasScrollView.fitHeightZoom(
            imageSize: CGSize(width: 2000, height: 1000),
            viewportSize: CGSize(width: 600, height: 800),
            padding: 16, scrollerWidth: 15)
        let documentHeight = (1000 + 32) * z
        XCTAssertLessThanOrEqual(documentHeight, 800 - 15)
        XCTAssertEqual(documentHeight, 800 - 15, accuracy: 1.0)
    }

    func test_fitWidthZoom_respectsManualCeiling() {
        // A tiny image would compute 1000/50 = 20, clamped to manualMaxZoom.
        let z = EditorCanvasScrollView.fitWidthZoom(
            imageWidth: 50, viewportWidth: 1000, padding: 0)
        XCTAssertEqual(z, EditorCanvasScrollView.manualMaxZoom, accuracy: 0.001)
    }

    func test_fitHeightZoom_upscalesSmallImage() {
        // ≈ 800 / 200 = 4.0 (minus the sub-pixel safety)
        let z = EditorCanvasScrollView.fitHeightZoom(
            imageHeight: 200, viewportHeight: 800, padding: 0)
        XCTAssertEqual(z, 4.0, accuracy: 0.01)
    }

    func test_fitWidthZoom_largeImageScalesDown() {
        // 2000-wide image into 1000 viewport => ≈ 0.5 (unchanged behavior).
        let z = EditorCanvasScrollView.fitWidthZoom(
            imageWidth: 2000, viewportWidth: 1000, padding: 0)
        XCTAssertEqual(z, 0.5, accuracy: 0.001)
    }

    func test_fitWidthZoom_accountsForScaledPadding() {
        // The padding border is part of the zoomed document: (1000 + 2·50)·z
        // must span the 1100 viewport => z ≈ 1.0.
        let z = EditorCanvasScrollView.fitWidthZoom(
            imageWidth: 1000, viewportWidth: 1100, padding: 50)
        XCTAssertEqual(z, 1.0, accuracy: 0.001)
    }

    func test_fitZoom_appliesInset() {
        // 1000x500 image into 1100x600 viewport with 50pt inset on each
        // side => effective viewport 1000x500 => fit = 1.0
        let z = EditorCanvasScrollView.fitZoom(
            imageSize: CGSize(width: 1000, height: 500),
            viewportSize: CGSize(width: 1100, height: 600),
            inset: 50
        )
        XCTAssertEqual(z, 1.0, accuracy: 0.001)
    }

    // MARK: - objectFitZoom (double-click an image object)

    func test_objectFitZoom_smallObject_zoomsInPast100() {
        let z = EditorCanvasScrollView.objectFitZoom(
            objectSize: CGSize(width: 200, height: 80),
            viewportSize: CGSize(width: 1000, height: 800),
            inset: 16)
        XCTAssertEqual(z, (1000 - 32) / 200, accuracy: 0.001)   // width-bound, 4.84 > 1.0
    }

    func test_objectFitZoom_largeObject_zoomsOut() {
        let z = EditorCanvasScrollView.objectFitZoom(
            objectSize: CGSize(width: 4000, height: 1000),
            viewportSize: CGSize(width: 1000, height: 800),
            inset: 16)
        XCTAssertEqual(z, (1000 - 32) / 4000, accuracy: 0.001)  // < 1.0
    }

    func test_objectFitZoom_clampsToManualCeilingAndFloor() {
        XCTAssertEqual(EditorCanvasScrollView.objectFitZoom(
            objectSize: CGSize(width: 2, height: 2),
            viewportSize: CGSize(width: 1000, height: 800), inset: 16),
            EditorCanvasScrollView.manualMaxZoom)
        XCTAssertEqual(EditorCanvasScrollView.objectFitZoom(
            objectSize: CGSize(width: 100_000, height: 100_000),
            viewportSize: CGSize(width: 1000, height: 800), inset: 16),
            EditorCanvasScrollView.minZoom)
    }

    func test_objectFitZoom_degenerateObject_returns1() {
        XCTAssertEqual(EditorCanvasScrollView.objectFitZoom(
            objectSize: .zero, viewportSize: CGSize(width: 1000, height: 800), inset: 16), 1)
    }

    // MARK: - 100% is magnetic

    // 100% is the only zoom that renders a byte-exact copy of the capture: the
    // blit is drawn 1:1 and the interpolation is nearest, so nothing is
    // resampled. One percent either side loses that — a trace of 70% -> 100%
    // ended with the model reading 1.0000 while the scroll view sat at 0.9900,
    // and the picture was a 1% resample of itself. Rather than depend on an
    // animation landing exactly, pull anything close onto it.

    func test_nearlyUnityZoomSnapsTo100() {
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.99), 1.0, accuracy: 0.0001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(1.01), 1.0, accuracy: 0.0001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.9907), 1.0, accuracy: 0.0001,
                       "the exact value the failing trace ended on")
    }

    func test_deliberateZoomsNearbyAreNotSwallowed() {
        // The snap must be tight enough that a real zoom step still lands where
        // asked. The nearest steps to 1.0 are 1/1.25 = 0.8 and 1.25.
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.95), 0.95, accuracy: 0.0001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(1.05), 1.05, accuracy: 0.0001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(0.8), 0.8, accuracy: 0.0001)
        XCTAssertEqual(EditorCanvasScrollView.clampZoom(1.25), 1.25, accuracy: 0.0001)
    }
}
