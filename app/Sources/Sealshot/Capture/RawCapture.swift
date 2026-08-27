import AppKit
import CoreGraphics

/// Side-effect-free capture output. Returned by `RegionCapturer.captureRaw(_:)`
/// and `WindowCapturer.captureRaw(window:on:)` for the `⌘⇧S` save-as path,
/// which performs its own single write via NSSavePanel rather than going
/// through `CaptureConfig.defaultOutput` branches.
struct RawCapture {
    let image: CGImage
    let pngData: Data
    let screen: NSScreen
}
