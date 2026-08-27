import XCTest
@testable import Sealshot

final class TagAddCommitTests: XCTestCase {

    func testCommitKeepsTypedPluralVerbatim() {
        let r = TagAddFieldHandler.resolveCommit(input: "Bugs", existing: ["design"])
        XCTAssertEqual(r.tags, ["design", "bugs"])   // NOT singularized
        XCTAssertEqual(r.added, "bugs")
    }

    func testCommitFormatsButDoesNotApplySynonym() {
        let r = TagAddFieldHandler.resolveCommit(input: "Bug Report", existing: [])
        XCTAssertEqual(r.tags, ["bug-report"])        // kebab, NOT synonym→bug
        XCTAssertEqual(r.added, "bug-report")
    }

    func testCommitOfExistingTagIsNoOp() {
        let r = TagAddFieldHandler.resolveCommit(input: "design", existing: ["design"])
        XCTAssertEqual(r.tags, ["design"])
        XCTAssertNil(r.added)
    }

    func testCommitEmptyInputIsNoOp() {
        let r = TagAddFieldHandler.resolveCommit(input: "   ", existing: ["bug"])
        XCTAssertEqual(r.tags, ["bug"])
        XCTAssertNil(r.added)
    }
}
