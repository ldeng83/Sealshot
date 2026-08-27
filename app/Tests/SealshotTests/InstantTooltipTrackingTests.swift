import AppKit
import XCTest
@testable import Sealshot

@MainActor
final class InstantTooltipTrackingTests: XCTestCase {

    private func makeView() -> HoverTooltipView {
        HoverTooltipView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    }

    func testDefault_tracksOnlyWhileTheAppIsActive() {
        let view = makeView()
        view.updateTrackingAreas()
        let options = view.trackingAreas.map(\.options)
        XCTAssertTrue(options.contains { $0.contains(.activeInActiveApp) })
        XCTAssertFalse(options.contains { $0.contains(.activeAlways) })
    }

    /// The floating capture panel is a non-activating panel — it never makes
    /// Sealshot the active app — so `.activeInActiveApp` means its tooltips
    /// never fire at all.
    func testOptedIn_tracksWhileTheAppIsInactive() {
        let view = makeView()
        view.tracksWhileAppInactive = true
        let options = view.trackingAreas.map(\.options)
        XCTAssertTrue(options.contains { $0.contains(.activeAlways) })
        XCTAssertFalse(options.contains { $0.contains(.activeInActiveApp) })
    }
}
