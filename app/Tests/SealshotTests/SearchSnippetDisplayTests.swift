import XCTest
@testable import Sealshot

/// `searchSnippetDisplay` turns a raw FTS snippet (multi-line OCR text with
/// hit markers) into a one-line AttributedString where the first hit is
/// guaranteed visible near the front and every hit is bold.
final class SearchSnippetDisplayTests: XCTestCase {
    private let s = LibraryIndexDB.snippetHitStart
    private let e = LibraryIndexDB.snippetHitEnd

    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    private func boldRuns(_ a: AttributedString) -> [String] {
        a.runs.compactMap { run in
            run.inlinePresentationIntent == .stronglyEmphasized
                ? String(a.characters[run.range]) : nil
        }
    }

    func testCollapsesWhitespaceAndStripsMarkers() {
        let out = searchSnippetDisplay("a\nb \(s)test\(e) c")
        XCTAssertEqual(plain(out), "a b test c")
        XCTAssertEqual(boldRuns(out), ["test"])
    }

    func testNoMarkers_collapseOnly() {
        let out = searchSnippetDisplay("line1\nline2  spaced")
        XCTAssertEqual(plain(out), "line1 line2 spaced")
        XCTAssertEqual(boldRuns(out), [])
    }

    func testLateHit_rewindowedToVisible() throws {
        let prefix = String(repeating: "x", count: 40)
        let out = searchSnippetDisplay("\(prefix) \(s)needle\(e) tail")
        let text = plain(out)
        XCTAssertTrue(text.hasPrefix("…"), "dropped lead-in should be elided")
        XCTAssertTrue(text.hasSuffix(" tail"))
        XCTAssertEqual(boldRuns(out), ["needle"])
        let hitOffset = text.range(of: "needle").map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(hitOffset), 19,
                                 "hit must sit within the visible lead-in")
    }

    func testShortPrefix_notRewindowed() {
        let out = searchSnippetDisplay("abc \(s)hit\(e) def")
        XCTAssertEqual(plain(out), "abc hit def")
    }

    func testMultipleHits_allBold_windowOnFirst() {
        let out = searchSnippetDisplay("\(s)alpha\(e) mid \(s)beta\(e)")
        XCTAssertEqual(plain(out), "alpha mid beta")
        XCTAssertEqual(boldRuns(out), ["alpha", "beta"])
    }

    /// The real-world shape from the bug report: multi-line OCR snippet with
    /// the hit on a later line ("…d63\n* Plan dual-repo…\n• 26\nTest…").
    func testBugReport_multilineSnippet_hitBecomesVisible() throws {
        let raw = "…d63\n* Plan dual-repo markeul..\n.Dullc release (-zsn\n• 26\n\(s)Test\(e)…"
        let out = searchSnippetDisplay(raw)
        let text = plain(out)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual(boldRuns(out), ["Test"])
        let hitOffset = text.range(of: "Test").map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(hitOffset), 19)
    }
}
