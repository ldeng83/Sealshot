import AppKit
import CryptoKit
import ScreenCaptureKit

@MainActor
final class FullscreenCapturer {
    enum CaptureError: Error {
        case noDisplayID
        case noMatchingDisplay
    }

    private let config: CaptureConfig

    init(config: CaptureConfig) {
        self.config = config
    }

    /// Captures `screen` end-to-end and runs clipboard/file side-effects per
    /// `CaptureConfig.defaultOutput`. Unlike Region and Window paths, the
    /// `hotkey-to-fullscreen-output` span owned by `CaptureCoordinator` covers
    /// the entire envelope here, so this method does not begin its own outer
    /// span — only the internal `capture-to-output` span (consistent with the
    /// other capturers).
    func capture(on screen: NSScreen) async throws -> CaptureResult {
        let cgImage = try await captureCGImage(screen: screen)
        return try await finish(cgImage: cgImage, reference: screen.frame, screen: screen)
    }

    /// Capture every display and composite them into one image at their spatial
    /// layout (the "All Displays" choice). Assumes a uniform backing scale (the
    /// common case); mixed-DPI layouts are approximate.
    func captureAllDisplays() async throws -> CaptureResult {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw CaptureError.noMatchingDisplay }
        // One uniform output scale (highest display DPI) drives the whole stitch;
        // the layout is done in point-space by the stitcher, so mixed-scale
        // displays stay geometrically correct. See MultiDisplayStitcher.
        let scale = screens.map(\.backingScaleFactor).max() ?? 2
        var tiles: [(pointFrame: CGRect, image: CGImage)] = []
        for screen in screens {
            let cg = try await captureCGImage(screen: screen)
            tiles.append((screen.frame, cg))
        }
        guard let stitched = MultiDisplayStitcher.stitch(tiles, outputScale: scale) else {
            throw CaptureError.noMatchingDisplay
        }
        let reference = screens.reduce(CGRect.null) { $0.union($1.frame) }
        return try await finish(cgImage: stitched, reference: reference, screen: NSScreen.main ?? screens[0])
    }

    /// Capture from an already-frozen snapshot (the monitor picker's freeze-frame),
    /// running the same output pipeline as a live capture.
    func capture(frozenImage: CGImage, reference: CGRect, screen: NSScreen) async throws -> CaptureResult {
        try await finish(cgImage: frozenImage, reference: reference, screen: screen)
    }

    /// Shared tail: encode, resolve the naming window, write outputs, kick off
    /// metadata, and build the `CaptureResult`.
    private func finish(cgImage: CGImage, reference: CGRect, screen: NSScreen) async throws -> CaptureResult {
        let png = try CaptureOutputWriter.encodePNG(cgImage)

        // Resolve the on-screen window before writing so its title/app name the
        // file. The whole display is the reference, so the largest visible
        // window wins.
        let front = NSWorkspace.shared.frontmostApplication
        let ctx = await CaptureWindowContext.resolve(reference: reference)
        // Fall back to the frontmost app, but never to Sealshot itself.
        let app = ctx.app ?? CaptureSubject.nonSelfAppName(
            front?.localizedName, bundleID: front?.bundleIdentifier,
            ownBundleID: Bundle.main.bundleIdentifier)

        let outputSpan = SignpostMetrics.begin("capture-to-output")
        let destinations: (clipboardWritten: Bool, savedFileURL: URL?, packageKey: SymmetricKey?)
        do {
            destinations = try CaptureOutputWriter.writeOutput(
                cgImage: cgImage, pngData: png, config: config,
                title: ctx.title, app: app
            )
        } catch {
            SignpostMetrics.end(outputSpan)
            throw error
        }
        SignpostMetrics.end(outputSpan)

        if let savedURL = destinations.savedFileURL {
            MetadataCoordinator.shared.start(for: savedURL, sourceApp: app, windowTitle: ctx.title,
                                             captureKind: .screenshot, captureMode: .fullScreen,
                                             sourceBundleID: front?.bundleIdentifier,
                                             packageKey: destinations.packageKey, source: cgImage)
        }

        return CaptureResult(
            image: cgImage,
            pngData: png,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            screen: screen,
            clipboardWritten: destinations.clipboardWritten,
            savedFileURL: destinations.savedFileURL
        )
    }

    private func captureCGImage(screen: NSScreen) async throws -> CGImage {
        guard let displayID = DisplayResolver.displayID(for: screen) else {
            throw CaptureError.noDisplayID
        }
        let content = try await SCShareableContent.current
        guard let scDisplay = DisplayResolver.match(displayID: displayID, in: content.displays) else {
            throw CaptureError.noMatchingDisplay
        }

        // Exclude Sealshot's own windows so the editor / overlay never appear
        // in a full-screen capture, even if a window hasn't finished ordering out.
        let filter = SelfExcludingContentFilter.display(scDisplay, in: content)
        return try await ScreenCaptureCore.captureImage(
            filter: filter,
            sourceRectPoints: nil
        )
    }
}
