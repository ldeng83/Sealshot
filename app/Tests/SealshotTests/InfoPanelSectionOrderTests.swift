import XCTest
import AppKit
@testable import Sealshot

/// The file Info panel's section order:
///   Name → Summary → Tags → Details → Objects  (when FM available; keywords
///                                                folded into Summary, no header)
///   Name → Tags → Details → Objects             (when FM unavailable)
@MainActor
final class InfoPanelSectionOrderTests: XCTestCase {

    // The two ordering tests below assert both the FM-available and
    // FM-unavailable orderings. Both `AIAvailability.status` and
    // `AIFeaturePreference().enabled` read real machine state, so `setUp`
    // pins a known "available" baseline (individual tests further pin
    // `.unavailable(...)` for their second scenario) rather than letting the
    // host machine decide — otherwise these tests pass today only because
    // the dev Mac happens to have Apple Intelligence on.
    private var priorAIToggle: Bool!

    override func setUp() {
        super.setUp()
        priorAIToggle = AIFeaturePreference().enabled
        AIFeaturePreference().enabled = true
        AIAvailability.statusOverride = .available
    }

    override func tearDown() {
        AIAvailability.statusOverride = nil
        AIFeaturePreference().enabled = priorAIToggle
        super.tearDown()
    }

    private func makeImage(_ w: Int = 120, _ h: Int = 90) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    /// The ordered section-header titles rendered in the Info panel.
    private func sectionHeaders(for state: EditorState) -> [String] {
        let view = EditorToolPropertiesViews.makeInfo(state: state)
        let stack = view as! NSStackView
        return stack.arrangedSubviews.compactMap { ($0 as? SidebarSectionHeader)?.stringValue }
    }

    // MARK: - Image Info panel

    func test_imageInfo_noStandaloneKeywordsHeader() throws {
        let state = EditorState(
            sourceImage: makeImage(),
            sourceURL: URL(fileURLWithPath: "/tmp/info-order.seal", isDirectory: true))
        let headers = sectionHeaders(for: state)

        // "Smart Keywords" / "Keywords" must never appear as its own section header.
        XCTAssertFalse(headers.contains("SMART KEYWORDS"),
                       "Smart Keywords must not appear as a standalone section header (got: \(headers))")
        XCTAssertFalse(headers.contains("KEYWORDS"),
                       "Keywords must not appear as a standalone section header (got: \(headers))")
    }

    func test_imageInfo_sectionOrder_summary_then_tags() throws {
        // `setUp` already pins `.available`; assert the FM-available ordering.
        do {
            let state = EditorState(
                sourceImage: makeImage(),
                sourceURL: URL(fileURLWithPath: "/tmp/info-order.seal", isDirectory: true))
            let headers = sectionHeaders(for: state)
            let tagsIdx = try XCTUnwrap(headers.firstIndex(of: "TAGS"), "Tags header must be present")
            let summaryIdx = try XCTUnwrap(headers.firstIndex(of: "SUMMARY"),
                                           "Summary header must be present when FM is available")
            XCTAssertLessThan(summaryIdx, tagsIdx,
                              "Summary must precede Tags (got: \(headers))")
        }
        // A permanently-unavailable reason omits Summary outright (pinned
        // rather than read from the host, per the class doc comment).
        do {
            AIAvailability.statusOverride = .unavailable(.deviceNotEligible)
            let state = EditorState(
                sourceImage: makeImage(),
                sourceURL: URL(fileURLWithPath: "/tmp/info-order.seal", isDirectory: true))
            let headers = sectionHeaders(for: state)
            XCTAssertFalse(headers.contains("SUMMARY"), "no Summary when FM unavailable")
        }
    }

    func test_tagsSectionFollowsNameOrSummary() throws {
        // Keywords are always folded inside Summary — never their own header —
        // regardless of Foundation Model availability.
        // `setUp` already pins `.available`; assert Name → Summary → Tags.
        do {
            let state = EditorState(
                sourceImage: makeImage(),
                sourceURL: URL(fileURLWithPath: "/tmp/info-order.seal", isDirectory: true))
            let headers = sectionHeaders(for: state)
            let nameIdx = try XCTUnwrap(headers.firstIndex(of: "NAME"), "Name header must be present")
            let tagsIdx = try XCTUnwrap(headers.firstIndex(of: "TAGS"), "Tags header must be present")
            XCTAssertFalse(headers.contains("SMART KEYWORDS"),
                           "Smart Keywords must never be a standalone header (got: \(headers))")
            let summaryIdx = try XCTUnwrap(headers.firstIndex(of: "SUMMARY"),
                                           "Summary header must be present when FM is available")
            XCTAssertEqual(summaryIdx, nameIdx + 1, "Summary directly after Name (got: \(headers))")
            XCTAssertEqual(tagsIdx, summaryIdx + 1, "Tags directly after Summary (got: \(headers))")
        }
        // A permanently-unavailable reason omits Summary: Tags follows Name directly.
        do {
            AIAvailability.statusOverride = .unavailable(.deviceNotEligible)
            let state = EditorState(
                sourceImage: makeImage(),
                sourceURL: URL(fileURLWithPath: "/tmp/info-order.seal", isDirectory: true))
            let headers = sectionHeaders(for: state)
            let nameIdx = try XCTUnwrap(headers.firstIndex(of: "NAME"), "Name header must be present")
            let tagsIdx = try XCTUnwrap(headers.firstIndex(of: "TAGS"), "Tags header must be present")
            XCTAssertFalse(headers.contains("SUMMARY"), "no Summary when FM unavailable")
            XCTAssertFalse(headers.contains("SMART KEYWORDS"), "no Smart Keywords when FM unavailable")
            XCTAssertEqual(tagsIdx, nameIdx + 1, "Tags directly after Name (got: \(headers))")
        }
    }

    // MARK: - Video Info panel

    /// Builds a minimal video `.seal` package on disk and returns the ordered
    /// section-header titles from `makeInfo(state:)` for that video state.
    /// Uses the same `sectionHeaders(for:)` introspection helper as the image
    /// tests — `SidebarSectionHeader.stringValue` returns the uppercased text.
    private func infoSectionHeaders(
        forVideoWithSummary hasSummary: Bool,
        smartKeywords: [String],
        tags: [String]
    ) -> [String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-video.seal")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let meta = CaptureMetadata(
            generatedTitle: "Test Recording",
            userTitle: nil,
            tags: tags,
            smartKeywords: smartKeywords,
            category: .other,
            confidence: 1.0,
            generatorVersion: 1
        )
        let videoInfo = SealManifest.VideoInfo(
            durationSeconds: 30,
            hasAudio: false,
            summary: hasSummary ? "This is a test video summary." : nil
        )
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: "2026-06-29T00:00:00Z",
            modifiedISO8601: "2026-06-29T00:00:00Z",
            sourceSize: SealManifest.Size(width: 1920, height: 1080),
            sourceApp: nil,
            metadata: meta,
            captureKind: .screenRecording,
            video: videoInfo
        )
        guard let manifestData = try? manifest.encodeJSON() else { return [] }
        try? manifestData.write(to: dir.appendingPathComponent("manifest.json"))

        let state = EditorState(sourceImage: makeImage(), sourceURL: dir)
        state.playingVideoURL = dir
        return sectionHeaders(for: state)
    }

    func test_videoInfo_noStandaloneKeywordsHeader() throws {
        let headers = infoSectionHeaders(forVideoWithSummary: true,
                                         smartKeywords: ["k"], tags: ["t"])
        XCTAssertFalse(headers.contains("SMART KEYWORDS"),
                       "Smart Keywords must not appear as a standalone section header (got: \(headers))")
        XCTAssertFalse(headers.contains("KEYWORDS"),
                       "Keywords must not appear as a standalone section header (got: \(headers))")
    }

    func test_videoInfo_sectionOrder_summary_then_tags() throws {
        let headers = infoSectionHeaders(forVideoWithSummary: true,
                                         smartKeywords: ["k"], tags: ["t"])
        // Tags section is always rendered (unconditional).
        let tagsIdx = try XCTUnwrap(headers.firstIndex(of: "TAGS"),
                                    "Tags header must be present in video Info panel (got: \(headers))")
        // Summary appears when manifest.video.summary is non-nil (not FM-gated).
        let summaryIdx = try XCTUnwrap(headers.firstIndex(of: "SUMMARY"),
                                       "Summary header must be present when video has a summary (got: \(headers))")
        XCTAssertLessThan(summaryIdx, tagsIdx, "Summary must precede Tags (got: \(headers))")
    }
}
