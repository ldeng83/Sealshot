import AppKit
import CryptoKit
import ScreenCaptureKit

@MainActor
final class WindowCapturer {
    enum CaptureError: Error {
        case noMatchingWindow
    }

    private let config: CaptureConfig

    init(config: CaptureConfig) {
        self.config = config
    }

    /// Side-effect-free capture of a single window. Used by `⌘⇧S` save-as.
    func captureRaw(window: SCWindow, on screen: NSScreen) async throws -> RawCapture {
        let selectionSpan = SignpostMetrics.begin("selection-to-capture")
        let cgImage: CGImage
        do {
            cgImage = try await captureCGImage(window: window, on: screen)
        } catch {
            SignpostMetrics.end(selectionSpan)
            throw error
        }
        SignpostMetrics.end(selectionSpan)

        let png = try CaptureOutputWriter.encodePNG(cgImage)
        return RawCapture(image: cgImage, pngData: png, screen: screen)
    }

    /// Full window capture with clipboard/file side effects per `CaptureConfig.defaultOutput`.
    func capture(window: SCWindow, on screen: NSScreen) async throws -> CaptureResult {
        let raw = try await captureRaw(window: window, on: screen)
        return try finishCapture(raw: raw, window: window)
    }

    /// Output-side half of a window capture (naming, clipboard/file, metadata)
    /// for an image already in hand — e.g. the window's rect cropped from a
    /// frozen frame (WYSIWYG: exactly what was on screen at freeze time).
    func finishCapture(image: CGImage, window: SCWindow, on screen: NSScreen) throws -> CaptureResult {
        let raw = RawCapture(
            image: image,
            pngData: try CaptureOutputWriter.encodePNG(image),
            screen: screen
        )
        return try finishCapture(raw: raw, window: window)
    }

    private func finishCapture(raw: RawCapture, window: SCWindow) throws -> CaptureResult {
        let app = window.owningApplication?.applicationName
            ?? NSWorkspace.shared.frontmostApplication?.localizedName

        let outputSpan = SignpostMetrics.begin("capture-to-output")
        let destinations: (clipboardWritten: Bool, savedFileURL: URL?, packageKey: SymmetricKey?)
        do {
            destinations = try CaptureOutputWriter.writeOutput(
                cgImage: raw.image, pngData: raw.pngData, config: config,
                title: window.title, app: app
            )
        } catch {
            SignpostMetrics.end(outputSpan)
            throw error
        }
        SignpostMetrics.end(outputSpan)

        if let savedURL = destinations.savedFileURL {
            MetadataCoordinator.shared.start(
                for: savedURL, sourceApp: app, windowTitle: window.title,
                captureKind: .screenshot, captureMode: .window,
                sourceBundleID: window.owningApplication?.bundleIdentifier,
                packageKey: destinations.packageKey, source: raw.image)
        }

        return CaptureResult(
            image: raw.image,
            pngData: raw.pngData,
            pixelSize: CGSize(width: raw.image.width, height: raw.image.height),
            screen: raw.screen,
            clipboardWritten: destinations.clipboardWritten,
            savedFileURL: destinations.savedFileURL
        )
    }

    private func captureCGImage(window: SCWindow, on screen: NSScreen) async throws -> CGImage {
        // Re-fetch shareable content so we have a fresh SCWindow handle —
        // the one captured by the picker may be stale.
        let content = try await SCShareableContent.current
        guard let fresh = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw CaptureError.noMatchingWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: fresh)
        return try await ScreenCaptureCore.captureImage(
            filter: filter,
            sourceRectPoints: nil
        )
    }
}
