import AppKit

/// Result of a single overlay session. The rect is in global AppKit
/// coordinates (bottom-left origin, points). `screen` identifies which
/// display the selection was drawn on — the same display will be used
/// for the SCK capture.
struct SelectedRegion {
    let globalRect: CGRect
    let screen: NSScreen
}
