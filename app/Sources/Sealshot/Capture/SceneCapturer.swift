import ScreenCaptureKit
import AppKit

enum SceneCapturer {
    /// Capture eligible windows + wallpapers into a scene.
    /// `displayID == nil` captures ALL displays (used for single-monitor and the
    /// ⌘-click "all monitors" gesture). A specific `displayID` restricts the
    /// scene to that monitor's wallpaper and the windows whose CENTER falls on
    /// it — mirroring how Full Screen capture scopes to one display.
    @MainActor
    static func capture(displayID: CGDirectDisplayID? = nil) async throws -> SceneCaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var windows = WindowCandidateProvider.candidates(in: content, ownPID: ownPID)
        var targetDisplays = content.displays
        var scale = NSScreen.main?.backingScaleFactor ?? 2.0

        if let displayID,
           let target = DisplayResolver.match(displayID: displayID, in: content.displays) {
            let frame = target.frame   // top-left global, same space as SCWindow.frame
            windows = windows.filter {
                frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            targetDisplays = [target]
            if let screen = NSScreen.screens.first(where: {
                DisplayResolver.displayID(for: $0) == displayID
            }) {
                scale = screen.backingScaleFactor
            }
        }

        var captured: [CapturedWindow] = []
        var skipped = 0
        for (i, w) in windows.enumerated() {   // provider returns front-to-back
            do {
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let img = try await ScreenCaptureCore.captureImage(
                    filter: filter, sourceRectPoints: nil, showsCursor: false)
                captured.append(CapturedWindow(
                    image: img, globalFrame: w.frame, z: i,
                    app: w.owningApplication?.applicationName ?? "",
                    bundleID: w.owningApplication?.bundleIdentifier ?? "",
                    title: w.title ?? ""))
            } catch { skipped += 1 }
        }

        var displays: [CapturedDisplay] = []
        for d in targetDisplays {
            let filter = SCContentFilter(display: d, excludingWindows: content.windows)
            if let wp = try? await ScreenCaptureCore.captureImage(
                filter: filter, sourceRectPoints: nil, showsCursor: false) {
                displays.append(CapturedDisplay(wallpaper: wp, globalFrame: d.frame))
            }
        }

        return SceneCaptureResult(windows: captured, displays: displays,
                                  scale: scale, skippedCount: skipped)
    }
}
