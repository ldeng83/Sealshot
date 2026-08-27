import XCTest
@testable import Sealshot

final class FeedbackBodyTests: XCTestCase {

    func test_subject_carriesVersionAndEdition() {
        XCTAssertEqual(
            FeedbackBody.subject(version: "0.3.0 (5)", edition: "Direct"),
            "Sealshot 0.3.0 (5) Direct — Feedback")
    }

    func test_body_containsAllFacts_andPromptLine() {
        let body = FeedbackBody.body(version: "0.3.0 (5)", edition: "Direct",
                                     osVersion: "Version 15.5 (Build 24F74)",
                                     arch: "arm64")
        XCTAssertTrue(body.contains("Sealshot 0.3.0 (5) — Direct edition"))
        XCTAssertTrue(body.contains("macOS Version 15.5 (Build 24F74) — arm64"))
        XCTAssertTrue(body.hasPrefix("(Describe your feedback above this line)") == false,
                      "prompt line leads the body so the cursor lands above the divider")
        XCTAssertTrue(body.contains("(Describe your feedback above this line)"))
    }

    func test_mailtoURL_encodesSubjectAndBody() throws {
        let url = try XCTUnwrap(FeedbackBody.mailtoURL(
            to: "feedback@seal-shot.com",
            subject: "Sealshot 0.3.0 (5) Direct — Feedback",
            body: "line one\nline two & more"))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:feedback@seal-shot.com?"))

        // Round-trip: the query items must decode back to the originals.
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["subject"], "Sealshot 0.3.0 (5) Direct — Feedback")
        XCTAssertEqual(items["body"], "line one\nline two & more")
        // Raw newlines must not survive un-encoded in the URL string.
        XCTAssertFalse(url.absoluteString.contains("\n"))
    }

    func test_currentArchitecture_isKnownValue() {
        XCTAssertTrue(["arm64", "x86_64"].contains(FeedbackBody.currentArchitecture()))
    }

    func test_defaultBody_usesLiveAppInfo() {
        let body = FeedbackBody.body()
        XCTAssertTrue(body.contains(AppInfo.versionString))
        XCTAssertTrue(body.contains(AppInfo.edition.label))
    }

    // MARK: mailto-handler gate

    @MainActor
    func test_shouldUseMailto_skipsAccountlessMail_acceptsThirdParty() {
        // Mail as handler at tier 2 ⇒ no account ⇒ its setup wizard is a
        // dead end; third-party handlers compose fine.
        XCTAssertFalse(FeedbackComposer.shouldUseMailto(handlerBundleID: "com.apple.mail"))
        XCTAssertTrue(FeedbackComposer.shouldUseMailto(handlerBundleID: "com.readdle.smartemail-Mac"))
        XCTAssertFalse(FeedbackComposer.shouldUseMailto(handlerBundleID: nil))
    }
}
