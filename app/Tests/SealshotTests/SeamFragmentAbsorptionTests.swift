import XCTest
@testable import Sealshot

/// Tile-seam truncated fragments: a tile whose edge cuts through a text line
/// still reads the part it can see, while the neighbouring (overlapping) tile
/// reads the whole line. `dedupLines` keeps both — the TEXTS differ at the
/// cut — polluting the layout and feeding aligned false evidence to the
/// column-gutter voter. `absorbSeamFragments` folds them into the fuller read.
final class SeamFragmentAbsorptionTests: XCTestCase {

    private func line(_ text: String, x: CGFloat, w: CGFloat,
                      y: CGFloat = 0.2) -> (line: RecognizedLine, conf: Float) {
        (RecognizedLine(text: text, box: CGRect(x: x, y: y, width: w, height: 0.015),
                        charBoxes: [], quad: nil), 0.95)
    }

    /// Right-truncated: the fragment shares the line's start, ends at the
    /// seam with a garbled cut glyph ("imaoe") — absorbed into the full read.
    func test_rightTruncatedFragment_absorbed() {
        let full = line("Smart Redact scans the image locally", x: 0.136, w: 0.200)
        let frag = line("Smart Redact scans the imaoe", x: 0.136, w: 0.141)  // ends 0.277
        let out = absorbSeamFragments([frag, full], seams: [0.277])
        XCTAssertEqual(out.map(\.line.text), [full.line.text])
    }

    /// Left-truncated: starts mid-word at the seam ("nage with…" from
    /// "image with…"), shares the line's end — absorbed.
    func test_leftTruncatedFragment_absorbed() {
        let full = line("image with a cancellable progress", x: 0.140, w: 0.210)
        let frag = line("nage with a cancellable progress", x: 0.181, w: 0.169)  // starts at seam
        let out = absorbSeamFragments([full, frag], seams: [0.181])
        XCTAssertEqual(out.map(\.line.text), [full.line.text])
    }

    /// The dangerous look-alike: a MERGED cross-column read contains its left
    /// cell's text AND box — but the cell's interior edge sits at the column
    /// gutter, not at a tile seam. The correct cell read must survive (the
    /// gutter repair handles the merged read, not this pass).
    func test_cellReadInsideMergedRead_notAbsorbed() {
        let merged = line("account holder name, 2. Click the pill", x: 0.10, w: 0.40)
        let cell = line("account holder name,", x: 0.10, w: 0.19)   // cut edge 0.29
        let out = absorbSeamFragments([cell, merged], seams: [0.45])
        XCTAssertEqual(out.count, 2, "cell read is not a seam fragment")
    }

    /// A similar-prefix line on a DIFFERENT row is its own read.
    func test_differentRow_notAbsorbed() {
        let full = line("Smart Redact scans the image locally", x: 0.136, w: 0.200, y: 0.20)
        let below = line("Smart Redact scans the imag", x: 0.136, w: 0.141, y: 0.24)
        XCTAssertEqual(absorbSeamFragments([below, full], seams: [0.277]).count, 2)
    }

    /// Contained box + seam-adjacent edge but UNRELATED text (an overlapping
    /// badge/label read) — kept.
    func test_unrelatedTextAtSeam_notAbsorbed() {
        let full = line("1. Open secrets-dump.png and inspect it", x: 0.10, w: 0.30)
        let other = line("P1 badge overlaps here", x: 0.10, w: 0.177)   // shares start, ends 0.277
        XCTAssertEqual(absorbSeamFragments([other, full], seams: [0.277]).count, 2)
    }

    /// No seams (single-pass image) → pass-through untouched.
    func test_noSeams_passThrough() {
        let full = line("Smart Redact scans the image locally", x: 0.136, w: 0.200)
        let frag = line("Smart Redact scans the imaoe", x: 0.136, w: 0.141)
        XCTAssertEqual(absorbSeamFragments([frag, full], seams: []).count, 2)
    }

    // MARK: - sameLineFragments (stitch pairing: titles by height, body by seam)

    /// Tall overlapping fragments stitch regardless of seams (title behavior).
    func test_stitchPair_tallFragments_noSeamNeeded() {
        let a = CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.03)
        let b = CGRect(x: 0.25, y: 0.10, width: 0.20, height: 0.03)
        XCTAssertTrue(sameLineFragments(a, b, seams: []))
    }

    /// Small-text overlapping fragments stitch ONLY when the overlap band
    /// sits at a tile seam — the signature of a seam split.
    func test_stitchPair_smallFragments_requireSeamInOverlap() {
        let a = CGRect(x: 0.30, y: 0.20, width: 0.16, height: 0.015)   // ends 0.46
        let b = CGRect(x: 0.44, y: 0.20, width: 0.13, height: 0.015)   // overlap [0.44, 0.46]
        XCTAssertTrue(sameLineFragments(a, b, seams: [0.445]))
        XCTAssertFalse(sameLineFragments(a, b, seams: [0.70]),
                       "small overlap away from any seam is the ambiguous dense-table case")
        XCTAssertFalse(sameLineFragments(a, b, seams: []))
    }

    /// Non-overlapping small boxes (distinct columns) never stitch, seam or not.
    func test_stitchPair_distinctColumns_neverStitch() {
        let a = CGRect(x: 0.10, y: 0.20, width: 0.15, height: 0.015)
        let b = CGRect(x: 0.40, y: 0.20, width: 0.15, height: 0.015)
        XCTAssertFalse(sameLineFragments(a, b, seams: [0.30]))
    }
}
