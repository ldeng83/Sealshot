import XCTest
import CoreGraphics
@testable import Sealshot

/// Unit tests for the pure decision helpers behind the low-confidence
/// region re-OCR pass (the crop+re-recognize accuracy step).
final class OCRRefinementTests: XCTestCase {

    // MARK: RefinementLimits policy matrix

    /// The safety property the whole design rests on: a caller that doesn't ask
    /// for a budget gets exactly the pre-budget behavior, on every machine.
    /// Smart Redaction matches Luhn-checked card numbers against this text, so
    /// a silent trim there would mean an undetected — and unredacted — card.
    func testFullPolicyIsUnbudgetedOnEveryMachine() {
        for machine in [OCRPerformanceClass.neuralEngine, .cpuOnly] {
            let limits = RefinementLimits.resolve(.full, on: machine)
            XCTAssertEqual(limits.maxLines, 40, "\(machine) must not cap a full pass")
            XCTAssertTrue(limits.useSharpenedVariant, "\(machine) must keep both crop variants")
        }
    }

    /// A Neural Engine absorbs the line count (~14ms/request measured), so the
    /// budget only drops the second crop variant there.
    func testBudgetedOnNeuralEngineOnlyDropsTheSharpenedVariant() {
        let limits = RefinementLimits.resolve(.budgeted, on: .neuralEngine)
        XCTAssertEqual(limits.maxLines, 40)
        XCTAssertFalse(limits.useSharpenedVariant)
    }

    /// Without a Neural Engine each re-read costs ~120ms, so the line count is
    /// capped too — this is what bounds the 15-37s field captures.
    func testBudgetedWithoutNeuralEngineCapsLinesAndVariants() {
        let limits = RefinementLimits.resolve(.budgeted, on: .cpuOnly)
        XCTAssertEqual(limits.maxLines, 8)
        XCTAssertFalse(limits.useSharpenedVariant)
        XCTAssertLessThan(limits.maxLines,
                          RefinementLimits.resolve(.full, on: .cpuOnly).maxLines)
    }

    /// Worst Vision requests per line, by policy — 2 when unbudgeted, 1 when
    /// budgeted. The pass's whole cost is request count.
    func testBudgetingAtMostHalvesRequestsPerLine() {
        let full = RefinementLimits.resolve(.full, on: .cpuOnly)
        let budgeted = RefinementLimits.resolve(.budgeted, on: .cpuOnly)
        func requests(_ l: RefinementLimits) -> Int {
            l.maxLines * (l.useSharpenedVariant ? 2 : 1)
        }
        XCTAssertEqual(requests(full), 80)
        XCTAssertEqual(requests(budgeted), 8)
    }

    // MARK: subdivideLineBox

    func testSubdivideTilesLineBoxExactly() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.05)
        let boxes = subdivideLineBox(box, count: 3)
        XCTAssertEqual(boxes.count, 3)
        XCTAssertEqual(boxes.first!.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(boxes.last!.maxX, 0.7, accuracy: 1e-9)
        for b in boxes {
            XCTAssertEqual(b.width, 0.2, accuracy: 1e-9)
            XCTAssertEqual(b.height, 0.05, accuracy: 1e-9)
            XCTAssertEqual(b.minY, 0.2, accuracy: 1e-9)
        }
    }

    func testSubdivideZeroCountIsEmpty() {
        XCTAssertTrue(subdivideLineBox(CGRect(x: 0, y: 0, width: 1, height: 1), count: 0).isEmpty)
    }

    // MARK: refinedText

    func testReplacesWhenSingleMoreConfidentCandidate() {
        // The exact case from the bug report: a confident-but-wrong "D8…" read
        // corrected by a higher-resolution re-OCR that sees "D6…".
        let r = refinedText(oldText: "D8H43ZFNQ", oldConfidence: 0.4,
                            candidates: [("D6H43ZFNQ", 0.7)])
        XCTAssertEqual(r, "D6H43ZFNQ")
    }

    func testKeepsWhenCandidateLessConfident() {
        XCTAssertNil(refinedText(oldText: "ABC", oldConfidence: 0.9,
                                 candidates: [("ABD", 0.5)]))
    }

    func testPicksClosestReReadWhenCropCaughtNeighbour() {
        // Close lines: the padded crop re-reads the target line ("D6…") AND
        // catches the neighbouring URL. We pick the near-match (the same line
        // re-read), not the unrelated neighbour. This is the real bug case.
        let r = refinedText(oldText: "D8H43ZFNQ", oldConfidence: 0.4,
                            candidates: [("D6H43ZFNQ", 0.7),
                                         ("mynetworksettings.com", 0.65)])
        XCTAssertEqual(r, "D6H43ZFNQ")
    }

    func testIgnoresWhenOnlyDistantCandidates() {
        // The crop only saw a wholly different (neighbour) line — not a re-read
        // of ours. Don't swap a code for an unrelated string.
        XCTAssertNil(refinedText(oldText: "D8H43ZFNQ", oldConfidence: 0.4,
                                 candidates: [("mynetworksettings.com", 0.95)]))
    }

    func testIgnoresEmptyCandidates() {
        XCTAssertNil(refinedText(oldText: "ABC", oldConfidence: 0.1, candidates: []))
    }

    func testIgnoresIdenticalText() {
        // Same string, no point swapping even if confidence ticked up.
        XCTAssertNil(refinedText(oldText: "ABC", oldConfidence: 0.4,
                                 candidates: [("ABC", 0.9)]))
    }

    // MARK: Background passes must be budgeted

    /// `.full` means "the user asked and is waiting"; `.budgeted` means
    /// "background work, don't hog the machine". The post-recording video pass
    /// is background work and OCRs up to 24 sampled frames, so an unbudgeted
    /// policy there multiplies the worst case by the frame count — minutes of
    /// continuous recognition on a Mac with no Neural Engine, for a recording
    /// the user has already walked away from.
    func testVideoFramePassIsBudgetedWithoutANeuralEngine() {
        let limits = RefinementLimits.resolve(VideoSummarizer.framePolicy, on: .cpuOnly)
        XCTAssertEqual(limits.maxLines, 8, "the automatic video pass must cap lines")
        XCTAssertFalse(limits.useSharpenedVariant,
                       "the automatic video pass must not pay for a second crop variant")
    }

    /// Even where each request is cheap, 24 frames of the second crop variant
    /// is pure waste for a pass nobody is watching.
    func testVideoFramePassDropsTheSecondVariantOnEveryMachine() {
        for machine in [OCRPerformanceClass.neuralEngine, .cpuOnly] {
            let limits = RefinementLimits.resolve(VideoSummarizer.framePolicy, on: machine)
            XCTAssertFalse(limits.useSharpenedVariant, "\(machine)")
        }
    }
}
