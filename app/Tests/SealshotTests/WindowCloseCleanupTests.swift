import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class WindowCloseCleanupTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        // Default is true, which makes close() release the window — ARC then
        // double-frees the test's own reference and crashes the runner. The real
        // permission/welcome panels set this to false too.
        window.isReleasedWhenClosed = false
        return window
    }

    func test_cleanupRunsWhenWindowCloses() {
        let window = makeWindow()
        var ran = 0
        WindowCloseCleanup.onClose(of: window) { ran += 1 }

        XCTAssertEqual(ran, 0, "cleanup must not run before the window closes")
        window.close()
        XCTAssertEqual(ran, 1, "cleanup must run exactly once when the window closes")
    }

    func test_cleanupFiresOnlyForItsOwnWindow() {
        let watched = makeWindow()
        let other = makeWindow()
        var ran = 0
        WindowCloseCleanup.onClose(of: watched) { ran += 1 }

        other.close()
        XCTAssertEqual(ran, 0, "closing a different window must not run the cleanup")

        watched.close()
        XCTAssertEqual(ran, 1)
    }

    func test_observerIsRemovedAfterFiring() {
        // A closed-then-(re)posted notification must not run cleanup twice; the
        // one-shot observer removes itself after the first willClose.
        let window = makeWindow()
        var ran = 0
        WindowCloseCleanup.onClose(of: window) { ran += 1 }

        window.close()
        // Re-post willClose for the same window; the observer should be gone.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(ran, 1, "cleanup must fire only once even if willClose is posted again")
    }
}
