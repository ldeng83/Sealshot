import XCTest
@testable import Sealshot

/// A scene summary lists every captured window as its own bullet. The window's
/// identity comes from the manifest and the sentence comes from the model, so
/// a window can never be renamed, merged, or dropped by the model — only its
/// description can fail.
final class SceneSummarizerTests: XCTestCase {

    private struct FakeDescriber: SceneWindowDescribing {
        var answers: [String: AIGenerationOutcome]
        func describe(windowText: String) async -> AIGenerationOutcome {
            answers[windowText] ?? .skip
        }
    }

    private func win(_ app: String, _ title: String, z: Int, _ text: String) -> SceneWindowText {
        SceneWindowText(app: app, title: title, z: z, text: text)
    }

    func test_oneBulletPerWindow_frontmostFirst() async {
        let windows = [
            win("Terminal", "zsh", z: 1, "make test"),
            win("Safari", "Start", z: 0, "Hello world"),
        ]
        let describer = FakeDescriber(answers: [
            "Hello world": .text("a news article about SwiftUI."),
            "make test": .text("a test run with failures."),
        ])
        let summary = await SceneSummarizer(describer: describer).summarize(windows)

        XCTAssertEqual(summary, """
        - Safari — Start: a news article about SwiftUI.
        - Terminal — zsh: a test run with failures.
        """)
    }

    /// A model failure must cost the description, never the window — the point
    /// of the feature is that the summary enumerates what was captured.
    func test_failedDescription_stillYieldsNameOnlyBullet() async {
        let windows = [
            win("Safari", "Start", z: 0, "Hello world"),
            win("Preview", "photo.png", z: 1, "IMG_0001"),
        ]
        let describer = FakeDescriber(answers: [
            "Hello world": .text("a news article."),
            "IMG_0001": .transient,
        ])
        let summary = await SceneSummarizer(describer: describer).summarize(windows)

        XCTAssertEqual(summary, """
        - Safari — Start: a news article.
        - Preview — photo.png
        """)
    }

    /// The prompt forbids line breaks, but assembling the list in code is
    /// exactly what stops "one bullet per window" depending on the model obeying
    /// instructions. An embedded newline would survive into the bullet,
    /// `SummaryLayout.parse` would read the continuation as an EXTRA bullet, and
    /// the bullet cap (= the window count) would then drop a real window.
    func test_multiLineSentence_stillYieldsOneBulletPerWindow() async {
        let windows = [
            win("Safari", "Start", z: 0, "Hello world"),
            win("Terminal", "zsh", z: 1, "make test"),
        ]
        let describer = FakeDescriber(answers: [
            "Hello world": .text("a news article\nabout SwiftUI navigation."),
            "make test": .text("a test run with failures."),
        ])
        let summary = await SceneSummarizer(describer: describer).summarize(windows)

        XCTAssertEqual(summary, """
        - Safari — Start: a news article about SwiftUI navigation.
        - Terminal — zsh: a test run with failures.
        """)
        XCTAssertEqual(summary?.components(separatedBy: "\n").count, 2)

        // And the clamp the scene path uses must keep both windows.
        let clamped = SummaryClamp.clamp(
            summary!, maxBullets: windows.count,
            maxBulletChars: SummaryClamp.sceneMaxBulletChars,
            maxTotalChars: SummaryClamp.totalBudget(
                bullets: windows.count, perBullet: SummaryClamp.sceneMaxBulletChars))
        XCTAssertEqual(clamped?.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(clamped!.contains("Terminal — zsh"))
    }

    func test_noWindows_isNil() async {
        let summary = await SceneSummarizer(
            describer: FakeDescriber(answers: [:])).summarize([])
        XCTAssertNil(summary, "nothing captured means nothing to summarize")
    }
}
