import AppKit

/// Ties a cleanup closure to a window's close, firing for ANY close path — the
/// title-bar close button, ⌘W, or a programmatic `close()`.
///
/// The permission and welcome panels store a reference the coordinator guards on
/// (`if permissionWindow != nil { return }`). Closing such a panel via its
/// title-bar X invokes neither the in-view Cancel nor the Done button, so
/// without this the stored reference would never clear — permanently blocking
/// reopening the panel, and therefore any capture that gates on it.
///
/// The observer fires once, then removes itself.
enum WindowCloseCleanup {
    private final class Box { var token: NSObjectProtocol? }

    @discardableResult
    static func onClose(of window: NSWindow, run cleanup: @escaping () -> Void) -> NSObjectProtocol {
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in
            if let token = box.token { NotificationCenter.default.removeObserver(token) }
            cleanup()
        }
        box.token = token
        return token
    }
}
