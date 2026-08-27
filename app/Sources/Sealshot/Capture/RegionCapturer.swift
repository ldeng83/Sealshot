import AppKit
import CryptoKit
import ScreenCaptureKit

@MainActor
final class RegionCapturer {
    enum CaptureError: Error {
        case noDisplayID
        case noMatchingDisplay
    }

    private let config: CaptureConfig
    /// Where a successful area capture is remembered, so it can be repeated.
    private let lastRegion: LastCaptureRegionStore

    init(config: CaptureConfig,
         lastRegion: LastCaptureRegionStore = LastCaptureRegionStore()) {
        self.config = config
        self.lastRegion = lastRegion
    }

    /// Side-effect-free capture. Used directly by the `⌘⇧S` save-as path
    /// and internally by `capture(_:)`.
    func captureRaw(_ region: SelectedRegion) async throws -> RawCapture {
        let selectionSpan = SignpostMetrics.begin("selection-to-capture")
        let cgImage: CGImage
        do {
            cgImage = try await captureCGImage(region)
        } catch {
            SignpostMetrics.end(selectionSpan)
            throw error
        }
        SignpostMetrics.end(selectionSpan)

        let png = try CaptureOutputWriter.encodePNG(cgImage)
        return RawCapture(image: cgImage, pngData: png, screen: region.screen)
    }

    /// Resolves the SCK display, filter and source rect for `region` ONCE
    /// and returns a sampler that only performs the screenshot. The
    /// scrolling-capture sampler calls this several times a second —
    /// re-enumerating shareable content per tick drags the cadence from
    /// 5 fps down to ~3, which makes outrunning the stitcher much easier.
    func frameSampler(for region: SelectedRegion) async throws -> @MainActor () async throws -> CGImage {
        let (filter, sourceRect) = try await resolveFilter(region)
        return {
            try await ScreenCaptureCore.captureImage(
                filter: filter,
                sourceRectPoints: sourceRect
            )
        }
    }

    /// Full capture with clipboard/file side effects per `CaptureConfig.defaultOutput`.
    func capture(_ region: SelectedRegion) async throws -> CaptureResult {
        let raw = try await captureRaw(region)
        return try await finishCapture(image: raw.image, pngData: raw.pngData, region: region)
    }

    /// Output-side half of a region capture (naming, clipboard/file, metadata)
    /// for an image that was already captured — e.g. cropped from a frozen
    /// frame. `pngData` may be passed when the caller already encoded it.
    func finishCapture(image: CGImage, pngData: Data? = nil, region: SelectedRegion,
                       mode: CaptureMode = .area) async throws -> CaptureResult {
        // Every route that captures an AREA lands here — the region hotkey,
        // the unified overlay's drag, and scrolling capture — which makes this
        // the one place that can remember what was captured without the three
        // callers drifting apart. Areas only: a scrolling capture's rect is a
        // viewport that was scrolled through, so repeating it as a still would
        // give back the first screenful and call it the same capture.
        if mode == .area, let id = DisplayIdentity.id(for: region.screen) {
            lastRegion.record(.init(rect: region.globalRect, displayID: id))
        }
        let raw = RawCapture(
            image: image,
            pngData: try pngData ?? CaptureOutputWriter.encodePNG(image),
            screen: region.screen
        )

        // Resolve the overlapped window before writing, so its title/app name
        // the file. (Synchronous now — the filename needs it.)
        let front = NSWorkspace.shared.frontmostApplication
        let ctx = await CaptureWindowContext.resolve(reference: region.globalRect)
        // Fall back to the frontmost app, but never to Sealshot itself (capture
        // is invoked from within it) — that yields a neutral "Screenshot" name.
        let app = ctx.app ?? CaptureSubject.nonSelfAppName(
            front?.localizedName, bundleID: front?.bundleIdentifier,
            ownBundleID: Bundle.main.bundleIdentifier)

        let outputSpan = SignpostMetrics.begin("capture-to-output")
        let destinations: (clipboardWritten: Bool, savedFileURL: URL?, packageKey: SymmetricKey?)
        do {
            destinations = try CaptureOutputWriter.writeOutput(
                cgImage: raw.image, pngData: raw.pngData, config: config,
                title: ctx.title, app: app
            )
        } catch {
            SignpostMetrics.end(outputSpan)
            throw error
        }
        SignpostMetrics.end(outputSpan)

        if let savedURL = destinations.savedFileURL {
            MetadataCoordinator.shared.start(for: savedURL, sourceApp: app, windowTitle: ctx.title,
                                             captureKind: .screenshot, captureMode: mode,
                                             sourceBundleID: front?.bundleIdentifier,
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

    private func captureCGImage(_ region: SelectedRegion) async throws -> CGImage {
        let (filter, sourceRect) = try await resolveFilter(region)
        return try await ScreenCaptureCore.captureImage(
            filter: filter,
            sourceRectPoints: sourceRect
        )
    }

    private func resolveFilter(_ region: SelectedRegion) async throws -> (SCContentFilter, CGRect) {
        let screen = region.screen

        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.noDisplayID
        }
        let displayID = CGDirectDisplayID(number.uint32Value)

        let content = try await SCShareableContent.current
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noMatchingDisplay
        }

        let local = CoordinateMath.displayLocalRect(
            global: region.globalRect,
            screenOrigin: screen.frame.origin
        )
        let sourceRect = CoordinateMath.flipY(
            localBottomLeft: local,
            screenHeight: screen.frame.height
        )

        // Exclude Sealshot's own windows so the editor / selection overlay never
        // appear in the captured region, regardless of orderOut timing.
        return (SelfExcludingContentFilter.display(scDisplay, in: content), sourceRect)
    }
}
