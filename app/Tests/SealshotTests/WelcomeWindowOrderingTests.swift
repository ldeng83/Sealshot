import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class WelcomeWindowOrderingTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        // close() would otherwise release the window and ARC double-frees the
        // test's own reference — same guard the real welcome window uses.
        window.isReleasedWhenClosed = false
        return window
    }

    override func tearDown() {
        // Leave no attached children behind between tests.
        for window in NSApp.windows { window.parent?.removeChildWindow(window) }
        super.tearDown()
    }

    // The bug: the editor raised itself to .floating and re-fronted itself
    // 0.25s after launch, burying the tour card that had already settled back
    // to .normal. A child window is "maintained in relative position ... for
    // subsequent ordering operations involving either window", so the card
    // stays above the editor regardless of level or timing.
    func test_cardBecomesChildOfEditorWindow() {
        let editor = makeWindow()
        let card = makeWindow()

        WelcomeWindowOrdering.present(card, above: editor)

        XCTAssertTrue(card.parent === editor, "tour card must be a child of the editor window")
        XCTAssertTrue(editor.childWindows?.contains(where: { $0 === card }) ?? false,
                      "editor must list the tour card among its children")
    }

    func test_attachedCardStaysAtNormalLevel() {
        let editor = makeWindow()
        let card = makeWindow()

        WelcomeWindowOrdering.present(card, above: editor)

        // Child ordering does the work; a raised level would trap the card on
        // top of OTHER apps' windows too (levels are system-wide, not app-scoped).
        XCTAssertEqual(card.level, .normal,
                       "attached card must not be raised above other apps")
    }

    func test_cardSurvivesEditorReFrontingItself() {
        let editor = makeWindow()
        let card = makeWindow()
        WelcomeWindowOrdering.present(card, above: editor)

        // The exact operation that used to bury the card at +0.25s.
        editor.level = .normal
        editor.orderFrontRegardless()

        XCTAssertTrue(card.parent === editor,
                      "tour card must stay attached after the editor re-fronts itself")
    }

    func test_cardDetachesAndStaysUpWhenEditorCloses() {
        // AppKit orders children out with their parent. Closing the editor
        // (⌘W) mid-tour must not take the card down with it — the user would
        // be left with no way to finish or dismiss it.
        let editor = makeWindow()
        let card = makeWindow()
        WelcomeWindowOrdering.present(card, above: editor)

        editor.close()

        XCTAssertNil(card.parent, "card must detach when its parent closes")
        XCTAssertTrue(card.isVisible, "card must stay on screen so the tour can be finished")
    }

    func test_noEditorWindowFallsBackToRaisedCard() {
        let card = makeWindow()

        WelcomeWindowOrdering.present(card, above: nil)

        XCTAssertNil(card.parent, "with no editor there is nothing to attach to")
        XCTAssertEqual(card.level, .floating,
                       "without a parent the card raises itself so it opens in front")
    }

    func test_raisedFallbackSettlesBackToNormal() {
        let card = makeWindow()
        WelcomeWindowOrdering.present(card, above: nil)

        // Staying .floating would pin the card over every other app.
        let settled = expectation(description: "card settles to .normal")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                XCTAssertEqual(card.level, .normal)
                settled.fulfill()
            }
        }
        wait(for: [settled], timeout: 2)
    }

    func test_cardIsNeverMadeAChildOfItself() {
        // Apple: "you should not create cycles between parent and child windows."
        let card = makeWindow()

        WelcomeWindowOrdering.present(card, above: card)

        XCTAssertNil(card.parent, "a window must not be attached to itself")
    }
}
