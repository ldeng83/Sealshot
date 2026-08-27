import XCTest
import CoreGraphics
import CoreImage
import ImageIO
@testable import Sealshot

/// Guards the invariant the refine budget rests on: budgeting may cost glyph
/// accuracy on low-confidence lines, but it must NEVER cost coverage.
///
/// `refineLowConfidenceLines` rewrites the string on lines pass 1 already
/// found — it cannot add or drop one. If that ever stops being true, budgeted
/// (automatic) recognition would silently index less text than a user-initiated
/// read of the same capture, and library search would quietly miss it.
@MainActor
final class OCRRefinementPolicyTests: XCTestCase {

    /// A downscaled fixture: blurred glyphs produce many low-confidence lines,
    /// so the budget's line cap actually binds. A clean screenshot has too few
    /// weak lines to exercise it.
    private func degradedFixture(_ name: String, scale: CGFloat) throws -> CGImage {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("poc/fixtures/\(name)")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let base = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let filter = try XCTUnwrap(CIFilter(name: "CILanczosScaleTransform"))
        filter.setValue(CIImage(cgImage: base), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        let out = try XCTUnwrap(filter.outputImage)
        let target = CGRect(x: 0, y: 0, width: CGFloat(base.width) * scale,
                            height: CGFloat(base.height) * scale)
        return try XCTUnwrap(CIContext().createCGImage(out, from: target))
    }

    func testBudgetingNeverChangesHowManyLinesAreFound() async throws {
        let image = try degradedFixture("stripe-or-billing.png", scale: 0.55)
        let recognizer = TextRecognizer()

        let full = try await recognizer.recognize(image, policy: .full)
        let budgeted = try await recognizer.recognize(image, policy: .budgeted)

        XCTAssertFalse(full.lines.isEmpty, "fixture must actually produce text")
        XCTAssertEqual(full.lines.count, budgeted.lines.count,
                       "budgeting must trade glyph accuracy, never coverage")
        // Geometry is pass-1's and is never touched by refinement, so the boxes
        // must line up one-for-one too — only strings may differ.
        for (f, b) in zip(full.lines, budgeted.lines) {
            XCTAssertEqual(f.box, b.box, "refinement must not move a line's box")
        }
    }

    /// The capture pipeline and the editor's Live Text overlay are handed the
    /// SAME CGImage instance, and the base pass (tiling — ~7s of a ~10.6s pass
    /// on Intel) doesn't depend on policy. The second consumer must reuse it
    /// and pay only for its own refinement.
    func testSecondRecognitionOfTheSameImageReusesTheBase() async throws {
        OCRBaseCache.shared.removeAll()
        let image = try degradedFixture("stripe-or-billing.png", scale: 0.55)
        let recognizer = TextRecognizer()

        // Hold the policy fixed so refinement cost is identical in both passes
        // and the ONLY difference is whether the base had to be recomputed.
        // (Comparing across policies would measure the refinement gap instead:
        // `.full` re-reads up to 40 weak lines with two crop variants where
        // `.budgeted` does 8 with one, which on a blurry fixture dwarfs the
        // base saving and hides it.) There is no finished-layout cache, so a
        // faster second pass can only come from the shared base.
        let coldStart = ContinuousClock.now
        let first = try await recognizer.recognize(image, policy: .full)
        let cold = ContinuousClock.now - coldStart

        let warmStart = ContinuousClock.now
        let second = try await recognizer.recognize(image, policy: .full)
        let warm = ContinuousClock.now - warmStart

        XCTAssertEqual(first.lines.map(\.text), second.lines.map(\.text),
                       "a reused base must produce the same text as a fresh one")
        XCTAssertLessThan(warm, cold,
                          "the second pass must reuse the base rather than re-tile")
    }

    /// The real capture flow: the metadata pipeline reads the image under a
    /// budget first, then the editor's Live Text overlay reads the same
    /// instance at full quality. The editor must still get FULL refinement —
    /// sharing the base must never silently downgrade it to the budgeted read.
    func testEditorStillGetsFullRefinementAfterABudgetedPass() async throws {
        OCRBaseCache.shared.removeAll()
        let image = try degradedFixture("stripe-or-billing.png", scale: 0.55)
        let recognizer = TextRecognizer()

        _ = try await recognizer.recognize(image, policy: .budgeted)   // metadata
        let shared = try await recognizer.recognize(image, policy: .full)  // editor

        OCRBaseCache.shared.removeAll()
        let independent = try await recognizer.recognize(image, policy: .full)

        XCTAssertEqual(shared.lines.map(\.text), independent.lines.map(\.text),
                       "a full read after a budgeted one must match an independent full read")
    }

    /// The field case store-on-completion did NOT cover: both consumers start
    /// before either finishes. Two overlapping reads produced two full bases
    /// (26.1s and 24.2s for work that takes ~10s alone) because each missed the
    /// cache and then contended. The late arrival must join the running
    /// computation instead of racing it.
    func testConcurrentReadersShareOneBase() async throws {
        OCRBaseCache.shared.removeAll()
        let image = try degradedFixture("stripe-or-billing.png", scale: 0.55)
        let recognizer = TextRecognizer()

        // Time one solo pass for reference, then clear so the pair start cold.
        let soloStart = ContinuousClock.now
        let solo = try await recognizer.recognize(image, policy: .full)
        let soloElapsed = ContinuousClock.now - soloStart
        OCRBaseCache.shared.removeAll()

        // Both launched before either can finish — the overlapping field case.
        let pairStart = ContinuousClock.now
        async let first = recognizer.recognize(image, policy: .budgeted)
        async let second = recognizer.recognize(image, policy: .full)
        let (a, b) = try await (first, second)
        let pairElapsed = ContinuousClock.now - pairStart

        XCTAssertEqual(a.lines.count, b.lines.count)
        XCTAssertEqual(b.lines.map(\.text), solo.lines.map(\.text),
                       "joining must not change the full-quality result")
        // Two independent passes would cost at least two bases and contend on
        // top; sharing keeps the pair near the cost of one pass plus the extra
        // refinement.
        XCTAssertLessThan(pairElapsed, soloElapsed * 2,
                          "overlapping readers must share the base, not race it")
    }

    /// Identity keying must not leak one image's text into another's result.
    func testDifferentImagesDoNotShareABase() async throws {
        OCRBaseCache.shared.removeAll()
        let a = try degradedFixture("stripe-or-billing.png", scale: 0.55)
        let b = try degradedFixture("terminal-dark.png", scale: 0.55)
        let recognizer = TextRecognizer()

        let first = try await recognizer.recognize(a, policy: .full)
        let second = try await recognizer.recognize(b, policy: .full)

        XCTAssertNotEqual(first.lines.map(\.text), second.lines.map(\.text),
                          "distinct images must produce distinct text")
    }

    /// The presence probe must agree with the full pipeline about whether there
    /// is text, while costing a fraction of it. It answers a boolean that used
    /// to be computed by running the whole pipeline (~28s in the field).
    func testContainsTextAgreesWithFullRecognitionButIsFarCheaper() async throws {
        let recognizer = TextRecognizer()
        let text = try degradedFixture("stripe-or-billing.png", scale: 0.55)

        let probeStart = ContinuousClock.now
        let probeSaysText = await recognizer.containsText(text)
        let probeElapsed = ContinuousClock.now - probeStart

        let fullStart = ContinuousClock.now
        let full = try await recognizer.recognize(text, policy: .full)
        let fullElapsed = ContinuousClock.now - fullStart

        XCTAssertTrue(probeSaysText, "probe must see the text the pipeline sees")
        XCTAssertFalse(full.lines.isEmpty)
        XCTAssertLessThan(probeElapsed, fullElapsed / 4,
                          "probe must be dramatically cheaper than full recognition")
    }

    /// A blank image has no text, and the probe must say so — a false positive
    /// would trigger the expensive super-resolution enhance it exists to avoid.
    func testContainsTextIsFalseForABlankImage() async throws {
        let ctx = CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        let blank = try XCTUnwrap(ctx.makeImage())

        let hasText = await TextRecognizer().containsText(blank)

        XCTAssertFalse(hasText)
    }

    /// `.full` is the default precisely so a new call site cannot silently
    /// inherit a budget — Smart Redaction and Live Text depend on that.
    func testDefaultPolicyIsFull() async throws {
        let image = try degradedFixture("stripe-or-billing.png", scale: 0.55)
        let recognizer = TextRecognizer()

        let implicit = try await recognizer.recognize(image)
        let explicitFull = try await recognizer.recognize(image, policy: .full)

        XCTAssertEqual(implicit.lines.map(\.text), explicitFull.lines.map(\.text))
    }
}
