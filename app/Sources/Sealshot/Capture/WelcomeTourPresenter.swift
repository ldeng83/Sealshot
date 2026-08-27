import AppKit
import SwiftUI

/// Owns the welcome-tour window, so it can be opened from two places without
/// either one stacking a second copy: `CaptureCoordinator.showWelcomeIfNeeded()`
/// at first launch (gated on `WelcomePreference`), and Settings ▸ Startup ▸
/// "Show Now", which shows the tour on demand regardless of that preference.
@MainActor
enum WelcomeTourPresenter {

    private static var window: NSWindow?

    /// Show the tour pinned above `parent` (the editor window). Already open →
    /// front the existing window instead of opening a second tour.
    static func present(above parent: NSWindow?) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = WelcomeView(onDone: { close() })
        let hosting = NSHostingController(rootView: view)
        // Fixed size set explicitly below; disable automatic window-size
        // tracking so content changes can't drive a re-entrant
        // updateWindowContentSizeExtrema crash on macOS 26 (see presentCenteredPanel).
        hosting.sizingOptions = []
        let card = NSWindow(contentViewController: hosting)
        card.styleMask = [.titled, .closable]
        card.title = "Welcome to Sealshot"
        card.isReleasedWhenClosed = false
        // True screen center — NSWindow.center() sits noticeably above it.
        // Fix the content size FIRST: the hosting view only sizes the window
        // when shown, and a post-show resize is top-left anchored, which
        // drags an early-positioned window toward the upper right.
        // sizingOptions = [] (crash guard) zeroes the live hosting view's
        // fittingSize; measure the natural size with a throwaway hosting view
        // that still reports it, so the window sizes and centers correctly.
        card.setContentSize(NSHostingView(rootView: view).fittingSize)
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let size = card.frame.size
            card.setFrameOrigin(NSPoint(
                x: v.midX - size.width / 2, y: v.midY - size.height / 2))
        }
        // Pin the card above the editor. A raise-then-settle here loses the
        // race: the editor is still `.floating` when the card drops back to
        // `.normal`, and re-fronts itself 0.25s later. Child ordering has no
        // such race, and leaves the app free to go behind other apps normally.
        WelcomeWindowOrdering.present(card, above: parent)
        WindowCloseCleanup.onClose(of: card) {
            if window === card { window = nil }
        }
        window = card
    }

    /// Close the tour ("Get Started"). Closing the window by any other route
    /// clears the reference through `WindowCloseCleanup` above.
    static func close() {
        window?.close()
        window = nil
    }
}
