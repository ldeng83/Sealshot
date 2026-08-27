import XCTest
@testable import Sealshot

/// Find in Image used to re-scan the capture on every keystroke: each
/// character drove `state.imageTextSearchQuery`, which re-ran the match and
/// redrew the canvas. Typing an eight-letter word cost eight full passes, most
/// of them for prefixes nobody wanted results for — and on a large capture on
/// Intel that is visible as the field lagging behind the keyboard.
///
/// The Library already solved this (`LibraryView.scheduleSearchReload`, 150ms),
/// so the interval matches rather than inventing a second feel. What the delay
/// must NOT do is make the panel feel broken: clearing has to empty the results
/// at once, and Return has to act on what is actually typed.
@MainActor
final class ImageTextSearchDebouncerTests: XCTestCase {

    private func makeDebouncer() -> (ImageTextSearchQueryDebouncer, () -> [String]) {
        let d = ImageTextSearchQueryDebouncer()
        var delivered: [String] = []
        d.onDeliver = { delivered.append($0) }
        return (d, { delivered })
    }

    func test_typingDoesNotDeliverImmediately() {
        let (d, delivered) = makeDebouncer()
        d.submit("inv")
        XCTAssertEqual(delivered(), [], "the whole point is not to search mid-word")
    }

    func test_clearingDeliversImmediately() {
        // Waiting to clear leaves highlights on a capture whose query is
        // visibly gone — it reads as a stuck panel.
        let (d, delivered) = makeDebouncer()
        d.submit("")
        XCTAssertEqual(delivered(), [""])
    }

    func test_whitespaceOnlyCountsAsClearing() {
        let (d, delivered) = makeDebouncer()
        d.submit("   ")
        XCTAssertEqual(delivered(), ["   "])
    }

    func test_flushDeliversWhatWasTyped() {
        // Return moves to the next result, so it has to act on the current text
        // rather than whatever the last completed search was.
        let (d, delivered) = makeDebouncer()
        d.submit("invoice")
        d.flush()
        XCTAssertEqual(delivered(), ["invoice"])
    }

    func test_rapidTypingCoalescesToTheLastQuery() {
        let (d, delivered) = makeDebouncer()
        d.submit("i")
        d.submit("in")
        d.submit("inv")
        d.flush()
        XCTAssertEqual(delivered(), ["inv"], "intermediate prefixes must not each search")
    }

    func test_flushWithNothingPendingDeliversNothing() {
        let (d, delivered) = makeDebouncer()
        d.flush()
        XCTAssertEqual(delivered(), [])
    }

    func test_flushTwiceDeliversOnce() {
        let (d, delivered) = makeDebouncer()
        d.submit("invoice")
        d.flush()
        d.flush()
        XCTAssertEqual(delivered(), ["invoice"])
    }

    func test_cancelDropsThePendingQuery() {
        // Switching capture, or closing the panel, must not land a search on
        // the capture that replaced it.
        let (d, delivered) = makeDebouncer()
        d.submit("invoice")
        d.cancel()
        d.flush()
        XCTAssertEqual(delivered(), [])
    }

    func test_typingEventuallyDeliversOnItsOwn() async throws {
        let (d, delivered) = makeDebouncer()
        d.submit("invoice")
        try await Task.sleep(for: .milliseconds(ImageTextSearchQueryDebouncer.typingDelayMilliseconds + 250))
        XCTAssertEqual(delivered(), ["invoice"], "the search still has to happen without Return")
    }

    func test_clearingAfterTypingCancelsThePendingSearch() async throws {
        let (d, delivered) = makeDebouncer()
        d.submit("invoice")
        d.submit("")
        try await Task.sleep(for: .milliseconds(ImageTextSearchQueryDebouncer.typingDelayMilliseconds + 250))
        XCTAssertEqual(delivered(), [""], "the abandoned query must never arrive after the clear")
    }
}
