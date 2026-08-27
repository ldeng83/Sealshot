import XCTest
import AppKit
@testable import Sealshot

/// The Info panel's Summary section when the Foundation Model is unavailable.
///
/// Actionable reason (Apple Intelligence merely switched off) → keep the
/// section and explain, so the feature is discoverable. Permanent reason
/// (ineligible Mac) → omit it exactly as before; a dead section on hardware
/// that can never run it is just clutter.
@MainActor
final class InfoPanelSummaryUnlockTests: XCTestCase {

    // The panel also reads Sealshot's own AI toggle (a real UserDefaults
    // value, not a test seam), so a developer who switched it off would make
    // these tests fail on their machine. Pin it to the "on" state the tests
    // assume, and restore whatever was there before.
    private var priorAIToggle: Bool!

    override func setUp() {
        super.setUp()
        priorAIToggle = AIFeaturePreference().enabled
        AIFeaturePreference().enabled = true
    }

    override func tearDown() {
        // Process-global seam — leaking it would corrupt every later test.
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

    private func infoStack() -> NSStackView {
        let state = EditorState(
            sourceImage: makeImage(),
            sourceURL: URL(fileURLWithPath: "/tmp/info-unlock.seal", isDirectory: true))
        return EditorToolPropertiesViews.makeInfo(state: state) as! NSStackView
    }

    private func sectionHeaders(_ stack: NSStackView) -> [String] {
        stack.arrangedSubviews.compactMap { ($0 as? SidebarSectionHeader)?.stringValue }
    }

    private func labelStrings(_ stack: NSStackView) -> [String] {
        stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    func test_appleIntelligenceOff_keepsSummarySectionVisible() {
        AIAvailability.statusOverride = .unavailable(.appleIntelligenceOff)
        let stack = infoStack()
        XCTAssertTrue(sectionHeaders(stack).contains("SUMMARY"),
                      "an actionable reason must leave the feature discoverable")
        // The header alone proves nothing — it would also survive a blank
        // summary editor or no affordance at all. Pin the actual unlock copy
        // so a regression there fails here, not just in the video panel.
        XCTAssertTrue(labelStrings(stack).contains(AINudgePolicy.summaryUnlockLine),
                      "the actionable reason must render its unlock explanation, not just the header")
    }

    func test_deviceNotEligible_omitsSummarySection() {
        AIAvailability.statusOverride = .unavailable(.deviceNotEligible)
        XCTAssertFalse(sectionHeaders(infoStack()).contains("SUMMARY"),
                       "a permanent reason keeps today's clean omission")
    }

    func test_notSupportedOS_omitsSummarySection() {
        AIAvailability.statusOverride = .unavailable(.notSupportedOS)
        XCTAssertFalse(sectionHeaders(infoStack()).contains("SUMMARY"),
                       "a permanent reason keeps today's clean omission")
    }

    func test_modelNotReady_omitsSummarySection() {
        AIAvailability.statusOverride = .unavailable(.modelNotReady)
        XCTAssertFalse(sectionHeaders(infoStack()).contains("SUMMARY"),
                       "a permanent reason keeps today's clean omission")
    }

    func test_aiToggleOff_omitsSummarySectionEvenWhenActionable() {
        // Sealshot's own switch outranks the system reason (AINudgePolicy):
        // someone who declined AI on purpose should not be pitched Apple
        // Intelligence just because the system reason happens to be the
        // actionable one.
        AIFeaturePreference().enabled = false
        AIAvailability.statusOverride = .unavailable(.appleIntelligenceOff)
        XCTAssertFalse(sectionHeaders(infoStack()).contains("SUMMARY"),
                       "the user's own AI toggle must win over an otherwise-actionable reason")
    }

    // MARK: - Video Info panel

    /// Builds a minimal video `.seal` package on disk and returns the Info
    /// panel's rendered stack for it. Same on-disk-manifest approach as
    /// `InfoPanelSectionOrderTests.infoSectionHeaders(forVideoWithSummary:...)`,
    /// but returns the whole stack (not just headers) so these tests can also
    /// inspect the unlock label and the summary editor's rendered text.
    private func videoInfoStack(hasSummary: Bool) -> NSStackView {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-video.seal")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let meta = CaptureMetadata(
            generatedTitle: "Test Recording",
            userTitle: nil,
            tags: [],
            smartKeywords: [],
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
        if let manifestData = try? manifest.encodeJSON() {
            try? manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        }

        let state = EditorState(sourceImage: makeImage(), sourceURL: dir)
        state.playingVideoURL = dir
        return EditorToolPropertiesViews.makeInfo(state: state) as! NSStackView
    }

    private func summaryEditorStrings(_ stack: NSStackView) -> [String] {
        stack.arrangedSubviews.compactMap { ($0 as? EditableSummaryView)?.string }
    }

    func test_videoInfo_appleIntelligenceOff_keepsSummarySectionVisible() {
        AIAvailability.statusOverride = .unavailable(.appleIntelligenceOff)
        let stack = videoInfoStack(hasSummary: false)
        XCTAssertTrue(sectionHeaders(stack).contains("SUMMARY"),
                      "an actionable reason must leave the video Summary section discoverable")
        XCTAssertTrue(labelStrings(stack).contains(AINudgePolicy.summaryUnlockLine),
                      "the video panel must render the same unlock line as the image panel")
    }

    func test_videoInfo_deviceNotEligible_omitsSummarySection() {
        AIAvailability.statusOverride = .unavailable(.deviceNotEligible)
        XCTAssertFalse(sectionHeaders(videoInfoStack(hasSummary: false)).contains("SUMMARY"),
                       "a permanent reason keeps the video panel's clean omission, same as the image panel")
    }

    func test_videoInfo_withGeneratedSummary_showsSummaryRegardlessOfStatus() {
        // A video that already has a generated summary shows it — the section
        // and its content do not depend on the current FM status, whether the
        // model happens to be available, off, or ineligible right now.
        for status: AIStatus in [.available,
                                 .unavailable(.appleIntelligenceOff),
                                 .unavailable(.deviceNotEligible)] {
            AIAvailability.statusOverride = status
            let stack = videoInfoStack(hasSummary: true)
            XCTAssertTrue(sectionHeaders(stack).contains("SUMMARY"),
                          "an existing summary must stay visible (status: \(status))")
            XCTAssertTrue(summaryEditorStrings(stack).contains("This is a test video summary."),
                          "the existing summary text must render, not the unlock affordance (status: \(status))")
            XCTAssertFalse(labelStrings(stack).contains(AINudgePolicy.summaryUnlockLine),
                           "an existing summary must not also show the unlock line (status: \(status))")
        }
    }
}
