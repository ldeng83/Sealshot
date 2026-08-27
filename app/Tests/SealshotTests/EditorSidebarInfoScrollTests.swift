import XCTest
import AppKit
@testable import Sealshot

/// The file Info panel can be taller than a short editor window (Name,
/// dimensions, dates, source app, size, tags). Its content must live inside a
/// vertical scroll view that fills the sidebar down to the bottom, so tall
/// content gains a scrollbar instead of overflowing off the bottom edge.
@MainActor
final class EditorSidebarInfoScrollTests: XCTestCase {

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func awaitTrailingWork() async {
        try? await Task.sleep(nanoseconds: 500_000_000)     // past any debounce
    }

    func test_infoPanelContentIsWrappedInVerticalScrollView() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let sidebar = EditorSidebarView(state: state)

        state.sidebarPanelMode = .info
        await awaitTrailingWork()

        guard let scroll = sidebar.debugHostScrollView else {
            XCTFail("Info panel must be hosted inside a scroll view")
            return
        }
        XCTAssertTrue(scroll.hasVerticalScroller,
                      "the Info scroll view must show a vertical scroller when content overflows")
        XCTAssertNotNil(scroll.documentView,
                        "the Info content must be the scroll view's document")
    }
}
