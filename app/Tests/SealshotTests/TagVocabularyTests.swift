import XCTest
@testable import Sealshot

final class TagVocabularyTests: XCTestCase {

    func testSuggestsComputedSingularEvenWhenNotInVocab() {
        let v = TagVocabulary(entries: [("design", 4)])
        let s = v.suggestions(for: "bugs", limit: 6)
        XCTAssertEqual(s.first, TagSuggestion(tag: "bug", kind: .canonical, count: nil))
    }

    func testCanonicalSuggestionCarriesVocabCountWhenPresent() {
        let v = TagVocabulary(entries: [("bug", 9), ("design", 4)])
        let s = v.suggestions(for: "bugs", limit: 6)
        XCTAssertEqual(s.first, TagSuggestion(tag: "bug", kind: .canonical, count: 9))
    }

    func testSynonymOffersCanonicalAsSuggestion() {
        let v = TagVocabulary(entries: [])
        let s = v.suggestions(for: "bug-report", limit: 6)
        XCTAssertEqual(s.first?.tag, "bug")
        XCTAssertEqual(s.first?.kind, .canonical)
    }

    func testPrefixThenFuzzyExistingSuggestions() {
        let v = TagVocabulary(entries: [("bug", 10), ("build", 4), ("backend", 3)])
        let tags = v.suggestions(for: "b", limit: 6).map(\.tag)
        XCTAssertEqual(tags, ["bug", "build", "backend"])
        // "buld" → "build": shares 'b', distance 1 (short word, ≤1). Kept.
        XCTAssertTrue(v.suggestions(for: "buld", limit: 6).map(\.tag).contains("build"))
    }

    func testFuzzyDropsDifferentFirstChar() {
        // "pet" is edit-distance 2 from "test" but starts with a different letter
        // — it must NOT be suggested.
        let v = TagVocabulary(entries: [("pet", 3)])
        XCTAssertTrue(v.suggestions(for: "test", limit: 6).isEmpty)
    }

    func testFuzzyShortWordRequiresSingleEdit() {
        // Short input (<6): only distance-1 fuzzy. "taste" is distance 2 from
        // "test" (shares 't') → dropped.
        let v = TagVocabulary(entries: [("taste", 3)])
        XCTAssertTrue(v.suggestions(for: "test", limit: 6).isEmpty)
    }

    func testFuzzyKeepsRealTypoOnLongerWord() {
        // "paymnt" (len 6) shares 'p', distance 1 from "payment" → kept.
        let v = TagVocabulary(entries: [("payment", 9)])
        XCTAssertEqual(v.suggestions(for: "paymnt", limit: 6).first?.tag, "payment")
    }

    func testNoCanonicalWhenTypedIsAlreadyCanonical() {
        // "focus" is protected (no singular) and not a synonym → no canonical row.
        let v = TagVocabulary(entries: [("focus", 5)])
        let s = v.suggestions(for: "focus", limit: 6)
        XCTAssertFalse(s.contains { $0.kind == .canonical })
    }

    func testEmptyPartialReturnsNothing() {
        XCTAssertTrue(TagVocabulary(entries: [("bug", 1)]).suggestions(for: "  ", limit: 6).isEmpty)
    }

    // MARK: smartKeywords excluded from vocabulary (Task 5)

    func test_vocabulary_excludes_smartKeywords() throws {
        // A row with tags:["mine"] and smartKeywords:["auto"] → vocabulary
        // should expose "mine" but NOT "auto" (allTags reads the tags column only).
        let db = try LibraryIndexDB(inMemoryFrom: nil)
        let r = CaptureIndexRow(path: "/lib/a.seal", folder: "/lib",
                                mtime: Date(), captureDate: Date(),
                                userTitle: nil, title: "t",
                                tags: ["mine"], smartKeywords: ["auto"])
        try db.upsert(r, ocrText: "")
        let vocab = try db.allTags()
        let tagNames = vocab.map(\.tag)
        XCTAssertTrue(tagNames.contains("mine"), "user tag 'mine' must appear in vocabulary")
        XCTAssertFalse(tagNames.contains("auto"), "smartKeyword 'auto' must NOT appear in vocabulary")
    }

    func testEditDistanceBasics() {
        XCTAssertEqual(TagVocabulary.editDistance("bug", "bog"), 1)
        XCTAssertEqual(TagVocabulary.editDistance("api", "app"), 1)
        XCTAssertEqual(TagVocabulary.editDistance("abc", "abc"), 0)
        XCTAssertEqual(TagVocabulary.editDistance("kitten", "sitting"), 3)
    }
}
