import AppKit
import CoreGraphics

/// Result of a successful `RegionCapturer.capture(_:)` call.
///
/// `clipboardWritten` and `savedFileURL` reflect *actual* per-destination success:
/// in `.both` mode, a file-write failure still returns a result with
/// `clipboardWritten == true, savedFileURL == nil`. The preview reads these to
/// pick its status text honestly.
struct CaptureResult {
    let image: CGImage
    let pngData: Data
    let pixelSize: CGSize
    let screen: NSScreen
    let clipboardWritten: Bool
    let savedFileURL: URL?
}
