import AppKit

/// Result of a region-overlay session.
/// `.cycle` means the user pressed spacebar to switch to window-picker mode.
enum OverlaySelection {
    case region(SelectedRegion)
    case cycle
    case cancelled
}
