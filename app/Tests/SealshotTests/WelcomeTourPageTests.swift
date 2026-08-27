import XCTest
@testable import Sealshot

/// The Intel list can only be checked through the `appleSilicon` parameter:
/// `RedactionEngineLoader.isAppleSilicon` is compile-time (`#if arch(arm64)`),
/// so an arm64 test run could never reach the Intel branch of a direct read.
final class WelcomeTourPageTests: XCTestCase {

    func test_appleSiliconSeesEveryPageInOrder() {
        XCTAssertEqual(WelcomeTourPage.visible(appleSilicon: true),
                       [.privacy, .captureRecord, .smarterRedaction, .editAnnotate,
                        .findOrganize, .shareProtect, .permissions])
    }

    func test_intelDropsTheSmarterRedactionPage() {
        // The enhanced model ships as an arm64-only plugin, so on Intel the card
        // could only say "you can't have this". Drop the whole page instead.
        let pages = WelcomeTourPage.visible(appleSilicon: false)
        XCTAssertFalse(pages.contains(.smarterRedaction))
        XCTAssertEqual(pages,
                       [.privacy, .captureRecord, .editAnnotate,
                        .findOrganize, .shareProtect, .permissions])
    }

    func test_onlyTheRedactionPageIsArchitectureGated() {
        // Guards against a future page being dropped on Intel by accident.
        let arm = WelcomeTourPage.visible(appleSilicon: true)
        let intel = WelcomeTourPage.visible(appleSilicon: false)
        XCTAssertEqual(arm.count - intel.count, 1)
        XCTAssertEqual(Set(arm).subtracting(intel), [.smarterRedaction])
    }
}
