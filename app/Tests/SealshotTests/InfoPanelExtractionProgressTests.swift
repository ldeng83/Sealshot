import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class InfoPanelExtractionProgressTests: XCTestCase {

    private func makeImage(_ w: Int = 8, _ h: Int = 8) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func headers(_ view: NSView) -> [String] {
        (view as! NSStackView).arrangedSubviews
            .compactMap { ($0 as? SidebarSectionHeader)?.stringValue }
    }

    private func hasProgressIndicator(_ view: NSView) -> Bool {
        func walk(_ v: NSView) -> Bool {
            if v is NSProgressIndicator { return true }
            return v.subviews.contains(where: walk)
        }
        return walk(view)
    }

    private var summaryEnabled: Bool {
        AIAvailability.isFoundationModelAvailable && AIFeaturePreference().enabled
    }

    private func state() -> EditorState {
        EditorState(sourceImage: makeImage(),
                    sourceURL: URL(fileURLWithPath: "/tmp/x.seal", isDirectory: true))
    }

    func test_tagsGenerating_showsProgressBar() {
        let s = state()
        s.isGeneratingTags = true
        let view = EditorToolPropertiesViews.makeInfo(state: s)
        XCTAssertTrue(headers(view).contains("TAGS"))
        XCTAssertTrue(hasProgressIndicator(view),
                      "an indeterminate progress bar must show while tags generate")
    }

    func test_summarySection_presenceMatchesFmAvailability() {
        let view = EditorToolPropertiesViews.makeInfo(state: state())
        XCTAssertEqual(headers(view).contains("SUMMARY"), summaryEnabled,
                       "Summary section shows iff Foundation Models is available and AI is enabled")
    }

    func test_summarySection_order_isBetweenNameAndTags_whenShown() throws {
        try XCTSkipUnless(summaryEnabled, "Summary section only present when FM available")
        let h = headers(EditorToolPropertiesViews.makeInfo(state: state()))
        let name = try XCTUnwrap(h.firstIndex(of: "NAME"))
        let summary = try XCTUnwrap(h.firstIndex(of: "SUMMARY"))
        let tags = try XCTUnwrap(h.firstIndex(of: "TAGS"))
        XCTAssertLessThan(name, summary)
        XCTAssertLessThan(summary, tags)
    }

    func test_summaryGenerating_showsProgressBar_whenSummaryEnabled() throws {
        try XCTSkipUnless(summaryEnabled, "Summary section only present when FM available")
        let s = state()
        s.isGeneratingSummary = true
        let view = EditorToolPropertiesViews.makeInfo(state: s)
        XCTAssertTrue(headers(view).contains("SUMMARY"))
        XCTAssertTrue(hasProgressIndicator(view),
                      "an indeterminate progress bar must show while the summary generates")
    }
}
