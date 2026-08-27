import XCTest
@testable import Sealshot

final class LicenseRenewalLinkTests: XCTestCase {
    /// The link used to carry `?license_id=…&email=…` for a checkout that would
    /// look the license up. Updates are permanent, the checkout is gone, and the
    /// page that replaced it reads neither parameter — so the app stopped
    /// sending a customer's email address into somebody's server logs to be
    /// ignored. The License ID the page asks for is on screen beside the link.
    func test_renewURLCarriesNoCustomerData() throws {
        let components = try XCTUnwrap(URLComponents(url: LicensingConfig.renewURL,
                                                     resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "www.seal-shot.com")
        XCTAssertEqual(components.path, "/renew")
        XCTAssertNil(components.query, "no query string: the page has nothing to look up")
    }

    /// The app must never link straight to a payment provider: changing
    /// products or providers would then require an app update that every
    /// existing user has to download. Doubly so here — this URL is compiled
    /// into builds up to 0.7.8 and can never be retired.
    func test_renewURLPointsAtOurSiteNotAPaymentProvider() {
        XCTAssertFalse(LicensingConfig.renewURL.absoluteString.contains("polar"))
    }
}
