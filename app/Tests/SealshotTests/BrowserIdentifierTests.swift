import XCTest
@testable import Sealshot

final class BrowserIdentifierTests: XCTestCase {
    func testWebKitFamily() {
        XCTAssertEqual(BrowserIdentifier.engine(for: "com.apple.Safari"), .webkit)
        XCTAssertEqual(BrowserIdentifier.engine(for: "com.apple.SafariTechnologyPreview"), .webkit)
    }
    func testChromiumFamily() {
        for id in ["com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
                   "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera",
                   "com.vivaldi.Vivaldi"] {
            XCTAssertEqual(BrowserIdentifier.engine(for: id), .chromium, "\(id)")
        }
    }
    func testGecko() {
        XCTAssertEqual(BrowserIdentifier.engine(for: "org.mozilla.firefox"), .gecko)
    }
    func testNonBrowserAndNil() {
        XCTAssertEqual(BrowserIdentifier.engine(for: "com.apple.finder"), .notBrowser)
        XCTAssertEqual(BrowserIdentifier.engine(for: nil), .notBrowser)
    }
    func testIsBrowserMatchesEngine() {
        XCTAssertTrue(BrowserIdentifier.isBrowser("com.google.Chrome"))
        XCTAssertFalse(BrowserIdentifier.isBrowser("com.apple.finder"))
        XCTAssertFalse(BrowserIdentifier.isBrowser(nil))
    }
    func testParityBrowsersClassifyAsChromium() {
        XCTAssertEqual(BrowserIdentifier.engine(for: "com.kagi.Orion"), .chromium)
        XCTAssertEqual(BrowserIdentifier.engine(for: "com.duckduckgo.macos.browser"), .chromium)
        XCTAssertTrue(BrowserIdentifier.isBrowser("com.kagi.Orion"))
        XCTAssertTrue(BrowserIdentifier.isBrowser("com.duckduckgo.macos.browser"))
    }
}
