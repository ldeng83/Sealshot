import AppKit
import ScreenCaptureKit

/// Convert a global AppKit point (bottom-left origin) to the Quartz/SCK global
/// point (top-left origin) used by `SCWindow.frame`. The flip anchor is the
/// display whose origin is (0,0). Pure — see `WindowHitTestTests`.
func appKitToQuartz(_ pointAppKit: CGPoint, primaryHeight: CGFloat) -> CGPoint {
    CGPoint(x: pointAppKit.x, y: primaryHeight - pointAppKit.y)
}

/// The front-most candidate window under the global AppKit cursor point, or
/// `nil` if none. `candidates` must already be in front-to-back order. Shared
/// by the window picker and the unified overlay.
func frontmostWindow(atGlobalAppKit mouseGlobal: CGPoint, in candidates: [SCWindow]) -> SCWindow? {
    // The y-flip anchor is the screen whose origin is (0,0) — the display that
    // defines the global coordinate origin.
    let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
        ?? NSScreen.screens.first
    guard let primary else { return nil }
    let mouseQuartz = appKitToQuartz(mouseGlobal, primaryHeight: primary.frame.height)
    return candidates.first(where: { $0.frame.contains(mouseQuartz) })
}
