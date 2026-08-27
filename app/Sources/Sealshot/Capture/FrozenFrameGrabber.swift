import AppKit
import ScreenCaptureKit

/// One display's frozen pixels, captured at trigger time.
struct FrozenFrame {
    let screen: NSScreen
    let image: CGImage
}

/// Everything snapshotted at the freeze moment: every display's fullscreen
/// image plus the window candidate list (frames can't move on a frozen
/// screen, so one snapshot replaces the live polling loop).
struct FrozenFrameSet {
    let frames: [FrozenFrame]
    let windows: [SCWindow]

    func frame(for screen: NSScreen) -> FrozenFrame? {
        frames.first { $0.screen == screen }
    }
}

/// Captures all displays (in parallel) the moment unified capture is
/// triggered, so the user selects on a frozen image — moving content is
/// already saved, and anything staged during a delayed-capture countdown
/// (menus, tooltips) survives into the capture.
@MainActor
enum FrozenFrameGrabber {
    enum GrabError: Error {
        case noDisplays
    }

    static func captureAll() async throws -> FrozenFrameSet {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw GrabError.noDisplays }
        let content = try await SCShareableContent.current
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Snapshot the window candidates NOW — same instant as the content
        // fetch, before the pixel grabs — so highlight rects date from the
        // freeze moment instead of a few hundred ms after (when dismissal /
        // menu-close animations have already moved things).
        let windows = WindowCandidateProvider.candidates(in: content, ownPID: ownPID)

        // Pair each NSScreen with its SCDisplay up front (skip unmatched).
        let pairs: [(NSScreen, SCDisplay)] = screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value })
            else { return nil }
            return (screen, display)
        }
        guard !pairs.isEmpty else { throw GrabError.noDisplays }

        // Grab every display concurrently; order doesn't matter.
        let frames = try await withThrowingTaskGroup(of: FrozenFrame.self) { group in
            for (screen, display) in pairs {
                group.addTask { @MainActor in
                    // Exclude Sealshot's own windows so the editor (frontmost
                    // when a capture is triggered from it) never lands in the
                    // frozen frame as a mid-orderOut translucent ghost.
                    let filter = SelfExcludingContentFilter.display(display, in: content)
                    let image = try await ScreenCaptureCore.captureImage(
                        filter: filter, sourceRectPoints: nil)
                    return FrozenFrame(screen: screen, image: image)
                }
            }
            var collected: [FrozenFrame] = []
            for try await frame in group { collected.append(frame) }
            return collected
        }

        return FrozenFrameSet(frames: frames, windows: windows)
    }
}
