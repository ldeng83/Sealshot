import XCTest
@testable import Sealshot

/// Filename composition: "<subject> <date>" with the configurable date format,
/// plus collision-bumping.
final class CaptureFilenameTests: XCTestCase {

    // 2026-06-09T13:09:10Z
    private let date = Date(timeIntervalSince1970: 1_781_010_550)
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let fmt = "yyyy-MM-dd 'at' HH_mm_ss"

    func testComposeBase_prependsSubject_withUnderscoreTime() {
        let base = CaptureConfig.composeBase(subject: "Google Chrome", format: fmt, at: date, timeZone: utc)
        XCTAssertEqual(base, "Google Chrome 2026-06-09 at 13_09_10")
    }

    func testComposeBase_noSubject_dateOnly() {
        let base = CaptureConfig.composeBase(subject: nil, format: fmt, at: date, timeZone: utc)
        XCTAssertEqual(base, "2026-06-09 at 13_09_10")
    }

    func testComposeBase_sanitizesIllegalChars() {
        let base = CaptureConfig.composeBase(subject: "a/b:c", format: fmt, at: date, timeZone: utc)
        // ":" and "/" are filesystem-illegal -> replaced with " - "
        XCTAssertTrue(base.hasPrefix("a - b - c "), "got \(base)")
        XCTAssertFalse(base.contains("/"))
        XCTAssertFalse(base.contains(":"))
    }

    // composeTitleAppBase: "<app> <title> <timestamp>"; title/app dropped when
    // empty, no double spaces.
    func testComposeTitleApp_appThenTitleDate() {
        let base = CaptureConfig.composeTitleAppBase(
            title: "Build failed 3 errors", app: "Xcode", format: fmt, at: date, timeZone: utc)
        XCTAssertEqual(base, "Xcode Build failed 3 errors 2026-06-09 at 13_09_10")
    }

    func testComposeTitleApp_emptyTitle_appAndDate() {
        let base = CaptureConfig.composeTitleAppBase(
            title: "", app: "Xcode", format: fmt, at: date, timeZone: utc)
        XCTAssertEqual(base, "Xcode 2026-06-09 at 13_09_10")
    }

    func testComposeTitleApp_nilBoth_dateOnly() {
        let base = CaptureConfig.composeTitleAppBase(
            title: nil, app: nil, format: fmt, at: date, timeZone: utc)
        XCTAssertEqual(base, "2026-06-09 at 13_09_10")
    }

    func testComposeTitleApp_sanitizesAndNoDoubleSpaces() {
        let base = CaptureConfig.composeTitleAppBase(
            title: "a/b", app: "  ", format: fmt, at: date, timeZone: utc)
        // app is whitespace-only -> dropped; title sanitized; single spaces only
        XCTAssertTrue(base.hasPrefix("a - b 2026-06-09"), "got \(base)")
        XCTAssertFalse(base.contains("  "))
        XCTAssertFalse(base.contains("/"))
    }

    func testUniqueName_firstFreeNameUsedAsIs() {
        let name = CaptureConfig.uniqueName(base: "Shot 2026", ext: "seal", exists: { _ in false })
        XCTAssertEqual(name, "Shot 2026.seal")
    }

    func testUniqueName_bumpsOnCollision() {
        let taken: Set<String> = ["Shot 2026.seal", "Shot 2026 2.seal"]
        let name = CaptureConfig.uniqueName(base: "Shot 2026", ext: "seal", exists: { taken.contains($0) })
        XCTAssertEqual(name, "Shot 2026 3.seal")
    }

    // Rename target: exactly the sanitized title (no timestamp appended), and a
    // no-op when it already matches — so repeated commits can't compound the name.
    func testRenameTarget_sameNameIsNoOp() {
        let t = CaptureConfig.renameTargetName(
            currentName: "YouTube Test.seal", title: "YouTube Test", ext: "seal", exists: { _ in true })
        XCTAssertNil(t)
    }

    func testRenameTarget_newTitle_noTimestampAppended() {
        let t = CaptureConfig.renameTargetName(
            currentName: "Google Chrome 2026-06-09 at 11_45_33.seal",
            title: "YouTube Test", ext: "seal", exists: { _ in false })
        XCTAssertEqual(t, "YouTube Test.seal")
    }

    func testRenameTarget_doesNotReappendExistingTimestamp() {
        // Committing the current display name (which includes a timestamp) again
        // must not append another timestamp — it's a no-op.
        let current = "YouTube Test 2026-06-09 at 11_45_33.seal"
        let t = CaptureConfig.renameTargetName(
            currentName: current, title: "YouTube Test 2026-06-09 at 11_45_33",
            ext: "seal", exists: { $0 == current })
        XCTAssertNil(t)
    }

    func testRenameTarget_collisionWithOtherFileBumps() {
        let t = CaptureConfig.renameTargetName(
            currentName: "Chrome.seal", title: "Report", ext: "seal", exists: { $0 == "Report.seal" })
        XCTAssertEqual(t, "Report 2.seal")
    }

    func testRenameTarget_sanitizesTitle() {
        let t = CaptureConfig.renameTargetName(
            currentName: "x.seal", title: "✳ YouTube", ext: "seal", exists: { _ in false })
        XCTAssertEqual(t, "YouTube.seal")
    }

    // A rename input with no letters or digits (only punctuation/dashes/dots,
    // or symbols that drop to nothing) has no valid string — it must fall back
    // to "screenshot.seal", never a bare ".seal" or an ugly/hidden filename.
    func testRenameTarget_punctuationOnly_fallsBackToScreenshot() {
        // Includes emoji carrying an invisible variation selector (U+FE0F, a
        // combining mark): "✳️" and "📊✳️" must NOT be treated as content —
        // otherwise sanitize leaves the lone selector and yields "️.seal".
        for junk in ["...", "///", "•••", "   ", "📊", "+++", "✳️", "📊✳️", "\u{2733}\u{FE0F}"] {
            let t = CaptureConfig.renameTargetName(
                currentName: "x.seal", title: junk, ext: "seal", exists: { _ in false })
            XCTAssertEqual(t, "screenshot.seal", "junk title \(junk) should fall back")
        }
    }

    func testRenameTarget_nonLatinLettersKept() {
        // CJK (and other non-Latin) letters are real content — not junk.
        let t = CaptureConfig.renameTargetName(
            currentName: "x.seal", title: "报告", ext: "seal", exists: { _ in false })
        XCTAssertEqual(t, "报告.seal")
    }

    func testRenameTarget_alreadyScreenshotFallback_isNoOp() {
        // Committing junk when the file is already the fallback name is a no-op
        // (no endless " 2" bumping).
        let t = CaptureConfig.renameTargetName(
            currentName: "screenshot.seal", title: "•••", ext: "seal", exists: { _ in true })
        XCTAssertNil(t)
    }

    func testRenameTarget_partialContentKept() {
        // A name with at least one alphanumeric is valid and kept (slashes still
        // sanitize to " - ").
        let t = CaptureConfig.renameTargetName(
            currentName: "x.seal", title: "a/b", ext: "seal", exists: { _ in false })
        XCTAssertEqual(t, "a - b.seal")
    }
}
