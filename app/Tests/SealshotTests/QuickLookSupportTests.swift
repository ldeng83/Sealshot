import XCTest
import AppKit
@testable import Sealshot

final class QuickLookSupportTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(fileURLWithPath: s) }

    // MARK: QuickLookToggle

    func test_toggle_openWhenOneSelected_closes() {
        let r = QuickLookToggle.resolve(currentlyOpen: true, selection: [u("/a")], anchor: u("/a"), firstItem: u("/a"))
        XCTAssertEqual(r, .init(open: false, selectURL: nil))
    }

    func test_toggle_closedWithOneSelected_opensNoReselect() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [u("/a")], anchor: u("/a"), firstItem: u("/a"))
        XCTAssertEqual(r, .init(open: true, selectURL: nil))
    }

    func test_toggle_closedNoSelection_selectsFirstAndOpens() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [], anchor: nil, firstItem: u("/first"))
        XCTAssertEqual(r, .init(open: true, selectURL: u("/first")))
    }

    func test_toggle_closedNoSelectionEmptyList_staysClosed() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [], anchor: nil, firstItem: nil)
        XCTAssertEqual(r, .init(open: false, selectURL: nil))
    }

    func test_toggle_closedManySelected_opensPreviewingAnchor() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [u("/a"), u("/b")], anchor: u("/b"), firstItem: u("/a"))
        XCTAssertEqual(r, .init(open: true, selectURL: u("/b")))
    }

    func test_toggle_closedManySelectedNoAnchor_opensPreviewingASelected() {
        let r = QuickLookToggle.resolve(currentlyOpen: false, selection: [u("/a"), u("/b")], anchor: nil, firstItem: u("/a"))
        // With no anchor, collapse to a deterministic selected URL (sorted-first).
        XCTAssertEqual(r, .init(open: true, selectURL: u("/a")))
    }

    // MARK: QuickLookFloatingPanel — keyboard routing after a click

    /// The reported bug (multi-monitor): click another app on the second
    /// display, click back on the preview, and Esc/arrows are dead. The panel is
    /// never-key AND non-activating, so its click changed nothing about who owned
    /// the keyboard — measured on the running app, frontmost stayed "Finder"
    /// after a click on the preview card. A click must repair both halves.
    func test_routingWork_appInactiveAndHostNotKey_activatesAndReKeys() {
        let work = QuickLookFloatingPanel.routingWork(appIsActive: false, hostIsKey: false)
        XCTAssertTrue(work.activate)
        XCTAssertTrue(work.makeKey)
    }

    /// Another Sealshot window took key while the app stayed active (e.g. a
    /// second editor on the other display): no activation needed, but the host
    /// still has to get the keyboard back.
    func test_routingWork_appActiveButHostNotKey_reKeysOnly() {
        let work = QuickLookFloatingPanel.routingWork(appIsActive: true, hostIsKey: false)
        XCTAssertFalse(work.activate)
        XCTAssertTrue(work.makeKey)
    }

    /// The ordinary case — clicking the preview of an app that already owns the
    /// keyboard must not churn activation or window order on every click.
    func test_routingWork_appActiveAndHostKey_doesNothing() {
        let work = QuickLookFloatingPanel.routingWork(appIsActive: true, hostIsKey: true)
        XCTAssertFalse(work.activate)
        XCTAssertFalse(work.makeKey)
    }

    /// No host (editor closed under the panel) reads as "nothing to re-key" —
    /// `restoreKeyboardRouting` passes `hostIsKey: true` for a nil host.
    func test_routingWork_noHost_reKeysNothing() {
        let work = QuickLookFloatingPanel.routingWork(appIsActive: true, hostIsKey: true)
        XCTAssertFalse(work.makeKey)
    }

    /// The fix must NOT make the panel key: the editor window keeps first
    /// responder (which is what stops AVPlayerView bouncing focus into the
    /// search field), and every preview key is routed by `EditorWindow`.
    @MainActor
    func test_panel_staysNeverKeyAndNeverMain() {
        let panel = QuickLookFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    /// The host reference must not keep a closed editor window alive.
    @MainActor
    func test_panel_holdsItsHostWindowWeakly() {
        let panel = QuickLookFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        autoreleasepool {
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.hostWindow = host
            XCTAssertNotNil(panel.hostWindow)
        }
        XCTAssertNil(panel.hostWindow, "a released editor window must not be retained")
    }

    /// End to end: a mouse-down delivered to the panel hands the keyboard back to
    /// the host. Runs only when the test host is already active — the point of
    /// the pure `routingWork` tests above is that the decision needs no
    /// activation, and forcing one here would yank focus off the user's screen.
    @MainActor
    func test_panelMouseDown_makesTheHostWindowKeyAgain() throws {
        try XCTSkipUnless(NSApp.isActive, "needs an active app to own key status")
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        defer { host.orderOut(nil); other.orderOut(nil) }
        host.makeKeyAndOrderFront(nil)
        other.makeKeyAndOrderFront(nil)
        try XCTSkipUnless(other.isKeyWindow, "another window must hold key for this to mean anything")

        let panel = QuickLookFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.hostWindow = host
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        panel.sendEvent(click)

        XCTAssertTrue(host.isKeyWindow, "clicking the preview must re-key its editor window")
        XCTAssertFalse(panel.isKeyWindow, "the panel itself still never takes key")
    }
}
