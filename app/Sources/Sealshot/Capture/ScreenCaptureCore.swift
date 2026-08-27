import ScreenCaptureKit
import CoreGraphics

/// The single ScreenCaptureKit capture entry point shared by every capture
/// path. Output pixel dimensions are derived from the filter's authoritative
/// `pointPixelScale` (never from `NSScreen.backingScaleFactor`), so mixed-DPI
/// setups capture at the correct resolution.
enum ScreenCaptureCore {
    /// - Parameters:
    ///   - filter: the SCK content filter (display- or window-scoped).
    ///   - sourceRectPoints: a display-local, top-left-origin sub-rect in
    ///     points, or `nil` to capture the filter's whole content.
    ///   - showsCursor: whether to composite the cursor into the capture.
    static func captureImage(
        filter: SCContentFilter,
        sourceRectPoints: CGRect?,
        showsCursor: Bool = false
    ) async throws -> CGImage {
        let scale = CGFloat(filter.pointPixelScale)
        // Snap the sub-rect to the pixel grid: a fractional `sourceRect` makes
        // ScreenCaptureKit bilinearly resample the whole capture, halving its
        // effective resolution. Mouse-drag selections are almost always
        // fractional, so without this the output looks soft next to a native
        // `screencapture`.
        let snappedSource = sourceRectPoints.map { CoordinateMath.snapToPixelGrid($0, scale: scale) }
        let regionPoints = snappedSource ?? filter.contentRect
        let (pxW, pxH) = CoordinateMath.pixelSize(points: regionPoints.size, scale: scale)

        let config = SCStreamConfiguration()
        if let src = snappedSource {
            config.sourceRect = src
        }
        config.width = pxW
        config.height = pxH
        config.scalesToFit = false
        config.showsCursor = showsCursor

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }
}
