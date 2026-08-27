import XCTest
@testable import Sealshot

/// The "subject" is the descriptive head of a capture name: the app first,
/// then the cleaned window/tab title when one exists ("Google Chrome - Page
/// Title"), else whichever part exists, else "Screenshot".
final class CaptureSubjectTests: XCTestCase {

    func testClean_stripsTrailingAppSuffix() {
        XCTAssertEqual(CaptureSubject.clean("Stripe Dashboard - Google Chrome"), "Stripe Dashboard")
        XCTAssertEqual(CaptureSubject.clean("AppDelegate.swift \u{2014} Sealshot"), "AppDelegate.swift")
    }

    func testClean_collapsesWhitespace() {
        XCTAssertEqual(CaptureSubject.clean("  Billing    Settings\n"), "Billing Settings")
    }

    func testClean_emptyOrNil_returnsNil() {
        XCTAssertNil(CaptureSubject.clean(nil))
        XCTAssertNil(CaptureSubject.clean("   \n "))
    }

    func testSubject_appFirstThenTitle() {
        XCTAssertEqual(
            CaptureSubject.subject(windowTitle: "Stripe Dashboard - Chrome", appName: "Google Chrome"),
            "Google Chrome - Stripe Dashboard")
    }

    func testSubject_appOnlyWhenNoTitle() {
        XCTAssertEqual(CaptureSubject.subject(windowTitle: nil, appName: "Google Chrome"), "Google Chrome")
        XCTAssertEqual(CaptureSubject.subject(windowTitle: "   ", appName: "Slack"), "Slack")
    }

    func testSubject_titleAloneWhenNoApp() {
        XCTAssertEqual(CaptureSubject.subject(windowTitle: "Release Notes", appName: nil),
                       "Release Notes")
    }

    func testSubject_noDuplicationWhenTitleEqualsApp() {
        // Some apps title their windows with just the app name.
        XCTAssertEqual(CaptureSubject.subject(windowTitle: "Finder", appName: "Finder"), "Finder")
    }

    func testSubject_fallsBackToScreenshot() {
        XCTAssertEqual(CaptureSubject.subject(windowTitle: nil, appName: nil), "Screenshot")
        XCTAssertEqual(CaptureSubject.subject(windowTitle: "", appName: "  "), "Screenshot")
    }

    func testSubject_capsCombinedLength() {
        let long = String(repeating: "A", count: 120)
        XCTAssertEqual(CaptureSubject.subject(windowTitle: long, appName: "App", maxLength: 50).count, 50)
        XCTAssertTrue(CaptureSubject.subject(windowTitle: long, appName: "App", maxLength: 50)
            .hasPrefix("App - A"))
    }

    func testNonSelfAppName_dropsOwnApp() {
        // Capturing from within Sealshot must not name the file after Sealshot.
        XCTAssertNil(CaptureSubject.nonSelfAppName("Sealshot", bundleID: "com.seal-shot.sealshot",
                                                   ownBundleID: "com.seal-shot.sealshot"))
    }

    func testNonSelfAppName_keepsOtherApps() {
        XCTAssertEqual(CaptureSubject.nonSelfAppName("Google Chrome", bundleID: "com.google.Chrome",
                                                     ownBundleID: "com.seal-shot.sealshot"), "Google Chrome")
    }

    func testNonSelfAppName_keepsWhenBundleUnknown() {
        XCTAssertEqual(CaptureSubject.nonSelfAppName("Some App", bundleID: nil,
                                                     ownBundleID: "com.seal-shot.sealshot"), "Some App")
    }
}
