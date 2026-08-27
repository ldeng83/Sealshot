import AppKit

/// The menu title for repeating the last capture.
///
/// Repeat fires with no overlay, no selection and no confirmation, so the menu
/// item is the only place that can tell the user what is about to be grabbed.
/// Showing the size turns a blind command into a legible one — and when the
/// remembered area is gone, saying so up front is better than a command that
/// silently means something else (it falls back to selecting a new area).
enum RepeatCaptureMenuTitle {
    static let base = "Repeat Last Capture"

    static func forRegion(_ region: SelectedRegion?) -> String {
        guard let region else { return base }
        return forSize(region.globalRect.size)
    }

    static func forSize(_ size: CGSize) -> String {
        // Points, rounded: the user drew this box with a pointer, and a
        // fractional drag ending at 640.3 is a 640-wide box to them. The
        // capture itself is still taken at the display's full backing scale.
        "\(base) (\(Int(size.width.rounded())) × \(Int(size.height.rounded())))"
    }
}
