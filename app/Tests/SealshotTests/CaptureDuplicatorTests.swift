import XCTest
@testable import Sealshot

final class CaptureDuplicatorTests: XCTestCase {

    func test_uniqueCopyName_firstCopy() {
        XCTAssertEqual(CaptureDuplicator.uniqueCopyName(base: "Shot", existing: []), "Shot copy")
    }

    func test_uniqueCopyName_incrementsPastClashes() {
        XCTAssertEqual(
            CaptureDuplicator.uniqueCopyName(base: "Shot", existing: ["Shot copy.seal"]),
            "Shot copy 2")
        XCTAssertEqual(
            CaptureDuplicator.uniqueCopyName(base: "Shot", existing: ["Shot copy.seal", "Shot copy 2.seal"]),
            "Shot copy 3")
    }

    func test_uniqueCopyName_ignoresUnrelatedFiles() {
        XCTAssertEqual(
            CaptureDuplicator.uniqueCopyName(base: "Shot", existing: ["Other.seal", "Shot.seal"]),
            "Shot copy")
    }

    func test_filenameSafe_replacesIllegalChars() {
        XCTAssertEqual(CaptureDuplicator.filenameSafe("a/b:c"), "a-b-c")
    }

    func test_filenameSafe_emptyFallsBack() {
        XCTAssertEqual(CaptureDuplicator.filenameSafe("   "), "Capture")
        XCTAssertEqual(CaptureDuplicator.filenameSafe(""), "Capture")
    }

    func test_uniqueCopyName_sanitizesBase() {
        XCTAssertEqual(CaptureDuplicator.uniqueCopyName(base: "a/b", existing: []), "a-b copy")
    }
}

/// Duplicating a copy used to stack suffixes — "Shot copy copy", then
/// "Shot copy copy copy". The counter never engaged because each longer name
/// was, of course, free. Numbering now continues from the stem.
final class CaptureDuplicatorCopyStemTests: XCTestCase {

    func test_duplicatingACopy_continuesTheNumbering() {
        XCTAssertEqual(
            CaptureDuplicator.uniqueCopyName(base: "Shot copy", existing: ["Shot copy.seal"]),
            "Shot copy 2")
    }

    func test_duplicatingANumberedCopy_continuesTheNumbering() {
        XCTAssertEqual(
            CaptureDuplicator.uniqueCopyName(
                base: "Shot copy 2",
                existing: ["Shot copy.seal", "Shot copy 2.seal"]),
            "Shot copy 3")
    }

    /// Repeated duplication must converge on numbers, never on a longer suffix.
    func test_repeatedDuplication_neverStacksSuffixes() {
        var existing: Set<String> = ["Shot.seal"]
        var name = "Shot"
        var produced: [String] = []
        for _ in 0..<4 {
            name = CaptureDuplicator.uniqueCopyName(base: name, existing: existing)
            existing.insert("\(name).seal")
            produced.append(name)
        }
        XCTAssertEqual(produced, ["Shot copy", "Shot copy 2", "Shot copy 3", "Shot copy 4"])
        XCTAssertFalse(produced.contains { $0.contains("copy copy") })
    }

    // MARK: The stem rule itself

    func test_copyStem_stripsOurSuffixes() {
        XCTAssertEqual(CaptureDuplicator.copyStem("Shot copy"), "Shot")
        XCTAssertEqual(CaptureDuplicator.copyStem("Shot copy 2"), "Shot")
        XCTAssertEqual(CaptureDuplicator.copyStem("Shot copy 17"), "Shot")
    }

    /// A leading space is required, so these are names rather than suffixes.
    func test_copyStem_leavesWordsContainingCopyAlone() {
        XCTAssertEqual(CaptureDuplicator.copyStem("Photocopy"), "Photocopy")
        XCTAssertEqual(CaptureDuplicator.copyStem("copycat"), "copycat")
        XCTAssertEqual(CaptureDuplicator.copyStem("Copy of the report"), "Copy of the report")
    }

    /// Matched case-insensitively so a renamed "Shot Copy" keeps counting…
    func test_copyStem_isCaseInsensitive() {
        XCTAssertEqual(CaptureDuplicator.copyStem("Shot Copy"), "Shot")
        XCTAssertEqual(CaptureDuplicator.copyStem("Shot COPY 3"), "Shot")
    }

    /// …but the emitted suffix stays lowercase, as it always has.
    func test_emittedSuffixStaysLowercase() {
        XCTAssertEqual(CaptureDuplicator.uniqueCopyName(base: "Shot Copy", existing: []),
                       "Shot copy")
    }

    /// A name that is nothing but the suffix has no stem worth keeping — it
    /// must not collapse to an empty filename.
    func test_copyStem_keepsANameThatIsOnlyTheSuffix() {
        XCTAssertEqual(CaptureDuplicator.copyStem("copy"), "copy")
        XCTAssertEqual(CaptureDuplicator.copyStem(" copy 2"), " copy 2")
        XCTAssertFalse(CaptureDuplicator.uniqueCopyName(base: "copy", existing: []).isEmpty)
    }

    /// Names ending in a number that is not a copy suffix are untouched.
    func test_copyStem_leavesOrdinaryTrailingNumbersAlone() {
        XCTAssertEqual(CaptureDuplicator.copyStem("Shot 2"), "Shot 2")
        XCTAssertEqual(CaptureDuplicator.copyStem("Screenshot 2026-08-14"), "Screenshot 2026-08-14")
    }
}
