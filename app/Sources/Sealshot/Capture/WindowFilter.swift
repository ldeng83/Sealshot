import CoreGraphics

/// Plain value-type view of an SCWindow, sufficient for the picker's
/// filtering rules. The mapping `[SCWindow] -> [WindowCandidate]` happens
/// in `WindowPickerController`; this lets the rules be unit-tested without
/// constructing SCWindow instances (which cannot be done outside SCK).
struct WindowCandidate: Equatable {
    let windowID: UInt32
    let owningPID: pid_t
    let owningBundleID: String?
    let isOnScreen: Bool
    let windowLayer: Int
    let frame: CGRect
}

/// Drops windows we never want to highlight in the picker:
///  - our own process (preview/overlay panels)
///  - WindowServer-owned (wallpaper, menu bar items, Dock)
///  - non-zero windowLayer (popovers, tooltips, sheets, status indicators)
///  - off-screen / minimized / hidden (isOnScreen == false)
///  - smaller than 100x100 (tray indicators, icons)
///
/// The `isOnScreen` filter is necessary: SCK keeps minimized and recently-
/// hidden windows in its list with their cached frame, which causes phantom
/// highlights over empty desktop regions. The Cmd+Tab-to-unminimize flow
/// still works because macOS sets `isOnScreen=true` at the start of the
/// unminimize animation, and the picker's 100ms poll catches it well before
/// the cursor can reach the restored window.
///
/// `windowLayer == 0` IS a filter: SCK returns *every* window owned by an
/// app as a separate `SCWindow`, including its toolbars, popovers, child
/// menus, and status accessories. Without this rule the picker's
/// "topmost-under-cursor" hit-test routinely lands on a tiny child window
/// rather than the visible parent.
///
/// Pure function — see WindowFilterTests.
internal func filterPickerCandidates(
    _ windows: [WindowCandidate],
    ownPID: pid_t
) -> [WindowCandidate] {
    let minArea: CGFloat = 100 * 100
    return windows.filter { w in
        guard w.isOnScreen else { return false }
        guard w.owningPID != ownPID else { return false }
        guard w.owningBundleID != "com.apple.WindowServer" else { return false }
        guard w.windowLayer == 0 else { return false }
        guard w.frame.width * w.frame.height >= minArea else { return false }
        return true
    }
}
