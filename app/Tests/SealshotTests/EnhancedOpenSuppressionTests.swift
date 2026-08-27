import XCTest
import CoreGraphics
@testable import Sealshot

/// Opening a capture used to restore whatever `showingEnhanced` the manifest
/// held, which meant decoding `enhanced.png` — a 2x-linear, 4x-pixel image — on
/// every switch, whether or not the user was looking at it. On a Mac with no
/// Neural Engine that decode is the dominant cost of switching captures (a
/// plain full capture already measures ~45ms there).
///
/// So on those machines a large capture opens with Enhance Clarity OFF and the
/// enhanced image left undecoded. The user can still turn it on, and the file
/// is untouched in the package — it is decoded on demand at that point.
@MainActor
final class EnhancedOpenSuppressionTests: XCTestCase {

    private func img(_ w: Int = 4, _ h: Int = 4) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    // MARK: - When to suppress

    func test_suppressed_forALargeCaptureWithoutANeuralEngine() {
        XCTAssertTrue(EditorState.suppressesEnhancedOnOpen(
            sourcePixels: 1785 * 1100, machine: .cpuOnly))
    }

    func test_notSuppressed_whenThereIsANeuralEngine() {
        // The decode is cheap enough there; leave the user's choice alone.
        XCTAssertFalse(EditorState.suppressesEnhancedOnOpen(
            sourcePixels: 1785 * 1100, machine: .neuralEngine))
    }

    func test_notSuppressed_forASmallCapture() {
        // A region grab decodes fast even on CPU — nothing to save.
        XCTAssertFalse(EditorState.suppressesEnhancedOnOpen(
            sourcePixels: 800 * 600, machine: .cpuOnly))
    }

    func test_thresholdIsOnTheSourceNotTheEnhancedImage() {
        // Stated explicitly because the COST is the enhanced image (4x these
        // pixels); the threshold is expressed in source pixels because that is
        // what the caller has before deciding whether to decode.
        let t = EditorState.enhanceAutoOffMinSourcePixels
        XCTAssertFalse(EditorState.suppressesEnhancedOnOpen(sourcePixels: t - 1, machine: .cpuOnly))
        XCTAssertTrue(EditorState.suppressesEnhancedOnOpen(sourcePixels: t, machine: .cpuOnly))
    }

    // MARK: - Suppression must not rewrite the user's stored choice

    func test_suppressingDoesNotPersistAsTheUsersPreference() {
        // The hazard: open with Enhance forced off, autosave fires, and the
        // manifest now says showingEnhanced=false — the user's choice silently
        // destroyed, including for the Retina Mac they open it on next. Same
        // problem `persistedShowingEnhanced` already solves for the Live Text
        // session's temporary flip.
        let s = EditorState(sourceImage: img(), sourceURL: nil,
                            enhancedImage: img(8, 8), showingEnhanced: true)
        s.suppressEnhancedForOpen()

        XCTAssertFalse(s.showingEnhanced, "the canvas shows the plain base")
        XCTAssertTrue(s.persistedShowingEnhanced,
                      "but a save must still record what the user chose")
    }

    func test_turningItOnClearsTheSuppression() {
        let s = EditorState(sourceImage: img(), sourceURL: nil,
                            enhancedImage: img(8, 8), showingEnhanced: true)
        s.suppressEnhancedForOpen()
        s.showingEnhanced = true

        XCTAssertTrue(s.persistedShowingEnhanced)
        XCTAssertTrue(s.showingEnhanced)
    }
}
