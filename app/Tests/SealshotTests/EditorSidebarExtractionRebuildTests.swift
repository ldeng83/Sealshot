import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class EditorSidebarExtractionRebuildTests: XCTestCase {

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }

    func test_togglingIsGeneratingTags_rebuildsSidebar() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let sidebar = EditorSidebarView(state: state)
        await settle()
        let before = sidebar.debugRebuildCount
        state.isGeneratingTags = true
        await settle()
        XCTAssertGreaterThan(sidebar.debugRebuildCount, before,
                             "flipping isGeneratingTags must rebuild the panel")
    }

    func test_togglingIsGeneratingSummary_rebuildsSidebar() async {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let sidebar = EditorSidebarView(state: state)
        await settle()
        let before = sidebar.debugRebuildCount
        state.isGeneratingSummary = true
        await settle()
        XCTAssertGreaterThan(sidebar.debugRebuildCount, before,
                             "flipping isGeneratingSummary must rebuild the panel")
    }
}
