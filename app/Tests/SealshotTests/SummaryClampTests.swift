import XCTest
@testable import Sealshot

final class SummaryClampTests: XCTestCase {

    func test_keepsCompleteSentencesAndAtMostThreeBullets() {
        let raw = """
        The dashboard shows Q2 sales. It also lists regions and reps.
        - North up 12%
        - South flat
        - West down 4%
        - East up 7%
        - Central new market
        """
        let out = try! XCTUnwrap(SummaryClamp.clamp(raw))
        let (overview, bullets) = SummaryLayout.parse(out)
        XCTAssertEqual(overview, "The dashboard shows Q2 sales. It also lists regions and reps.",
                       "complete sentences that fit the budget are all kept")
        XCTAssertEqual(bullets.count, 3, "at most three bullets")
        XCTAssertEqual(bullets, ["North up 12%", "South flat", "West down 4%"])
    }

    func test_capsTotalLength_forRunawayOutput() {
        // Simulate the model echoing dozens of fragments as bullets.
        let bullets = (0..<60).map { "- Fragment number \($0) with some extra words here" }
        let raw = (["A long overview sentence that rambles on well past any reasonable size limit."]
                   + bullets).joined(separator: "\n")
        let out = try! XCTUnwrap(SummaryClamp.clamp(raw))
        XCTAssertLessThanOrEqual(out.count, SummaryClamp.maxTotalChars)
    }

    func test_overviewOnly_noBullets() {
        let out = SummaryClamp.clamp("A single concise overview of the screen.")
        XCTAssertEqual(out, "A single concise overview of the screen.")
    }

    func test_emptyOrWhitespace_returnsNil() {
        XCTAssertNil(SummaryClamp.clamp(""))
        XCTAssertNil(SummaryClamp.clamp("   \n  \n"))
    }

    func test_longBulletIsTruncated_atWordBoundary() {
        let longBullet = Array(repeating: "word", count: 60).joined(separator: " ")
        let out = try! XCTUnwrap(SummaryClamp.clamp("Overview.\n- \(longBullet)"))
        let (_, bullets) = SummaryLayout.parse(out)
        XCTAssertEqual(bullets.count, 1)
        XCTAssertLessThanOrEqual(bullets[0].count, SummaryClamp.maxBulletChars)
        XCTAssertTrue(bullets[0].hasSuffix("…"), "truncation is marked")
        XCTAssertFalse(bullets[0].dropLast().hasSuffix("wor"), "never cut mid-word")
    }

    /// The shipped defect: a single overlong first sentence was chopped at
    /// prefix(160) mid-word ("…along with comments abo"). It must now cut at
    /// a word boundary with an ellipsis, so it reads as intentionally short.
    func test_overlongSingleSentence_cutAtWordBoundary_withEllipsis() {
        let sentence = "The screenshot contains "
            + Array(repeating: "alpha bravo charlie delta", count: 20).joined(separator: " ")
            + " and ends here."
        let out = try! XCTUnwrap(SummaryClamp.clamp(sentence))
        XCTAssertLessThanOrEqual(out.count, SummaryClamp.maxOverviewChars)
        XCTAssertTrue(out.hasSuffix("…"), "overflow is marked, not silently chopped")
        // The kept text must end on a complete word from the source.
        let kept = String(out.dropLast())
        XCTAssertTrue(sentence.contains(kept + " "), "cut landed mid-word: …\(kept.suffix(12))")
    }

    /// Multiple short sentences that fit must ALL survive (the old clamp threw
    /// away everything after the first sentence).
    func test_multipleShortSentences_allKept() {
        let raw = "Login page for Acme. Fields for email and password. A signup link sits below."
        XCTAssertEqual(SummaryClamp.clamp(raw), raw)
    }

    /// A quoted period mid-sentence must not strand an unbalanced quote (the
    /// old first-sentence cut produced «…and "Gaming.»). Splitting there is
    /// fine — the pieces are packed back together, so nothing is lost.
    func test_quotedPeriod_doesNotTruncateOrUnbalance() {
        let raw = "Videos are categorized under \"Nu-Metalcore\" and \"Gaming.\" More rows follow below."
        XCTAssertEqual(SummaryClamp.clamp(raw), raw)
    }

    func test_sentenceSplitter_shapes() {
        XCTAssertEqual(SummaryClamp.sentences("One. Two! Three?"), ["One.", "Two!", "Three?"])
        XCTAssertEqual(SummaryClamp.sentences("Version 3.5 shipped today."),
                       ["Version 3.5 shipped today."], "decimal points don't split")
        XCTAssertEqual(SummaryClamp.sentences("He said \"stop.\" Then left."),
                       ["He said \"stop.\"", "Then left."], "closing quote stays with its sentence")
        XCTAssertEqual(SummaryClamp.sentences("No terminator at all"),
                       ["No terminator at all"])
    }
}
