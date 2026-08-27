import XCTest
@testable import Sealshot

/// Live Capture stores each window as its own asset, so a scene's OCR text is
/// assembled from per-window reads rather than one pass over the image. The
/// labelled-block format is what makes a scene summary able to say WHICH
/// window said what — the label comes from the manifest, never the model.
final class SceneTextTests: XCTestCase {

    private func win(_ app: String, _ title: String, z: Int, _ text: String) -> SceneWindowText {
        SceneWindowText(app: app, title: title, z: z, text: text)
    }

    func test_label_joinsAppAndTitle() {
        XCTAssertEqual(SceneText.label(app: "Safari", title: "Apple Start Page"),
                       "Safari — Apple Start Page")
    }

    /// Untitled windows are common (panels, some utilities). The app name alone
    /// still identifies the window; a dangling separator would look broken.
    func test_label_appOnlyWhenTitleEmpty() {
        XCTAssertEqual(SceneText.label(app: "Terminal", title: ""), "Terminal")
        XCTAssertEqual(SceneText.label(app: "Terminal", title: "   "), "Terminal")
    }

    func test_aggregate_labelledBlocksFrontmostFirst() {
        let out = SceneText.aggregate([
            win("Terminal", "zsh", z: 1, "make test\nall green"),
            win("Safari", "Apple Start Page", z: 0, "Hello world"),
        ])
        XCTAssertEqual(out, """
        Safari — Apple Start Page
        Hello world

        Terminal — zsh
        make test
        all green
        """)
    }

    /// A window with no readable text contributes no block — an empty labelled
    /// heading would tell the summarizer a window said something when it didn't.
    func test_aggregate_dropsWindowsWithNoText() {
        let out = SceneText.aggregate([
            win("Safari", "Start", z: 0, "Hello"),
            win("Preview", "photo.png", z: 1, "   "),
        ])
        XCTAssertEqual(out, "Safari — Start\nHello")
    }

    func test_aggregate_emptyInputIsEmptyString() {
        XCTAssertEqual(SceneText.aggregate([]), "")
    }

    /// The aggregate feeds a model context budget; a huge scene must not blow it.
    func test_aggregate_truncatesToBudget() {
        let big = String(repeating: "x", count: 500)
        let out = SceneText.aggregate([win("A", "B", z: 0, big)], maxChars: 100)
        XCTAssertEqual(out.count, 100)
    }
}
