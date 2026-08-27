import AppKit
import ScreenCaptureKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "capture")

/// Fetches the on-screen windows eligible for highlighting, in true visual
/// front-to-back order. Shared by the window picker and the unified overlay.
///
/// SCK's `content.windows` order is not visual z-order, so ordering comes from
/// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` mapped back to the
/// `SCWindow` handles SCK needs for capture. `filterPickerCandidates` drops our
/// own panels, WindowServer chrome, child/popover layers, off-screen and tiny
/// windows.
enum WindowCandidateProvider {
    static func current(ownPID: pid_t) async -> [SCWindow] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            os_log("SCShareableContent failed: %{public}@",
                   log: log, type: .error, String(describing: error))
            return []
        }
        return candidates(in: content, ownPID: ownPID)
    }

    /// Order + filter the windows of an already-fetched content snapshot.
    /// Synchronous — `CGWindowListCopyWindowInfo` is sampled at call time, so
    /// call this at the moment the window list should date from (e.g., the
    /// freeze instant, alongside the content fetch the frame grab uses).
    static func candidates(in content: SCShareableContent, ownPID: pid_t) -> [SCWindow] {
        let cgInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let visualOrderIDs: [CGWindowID] = cgInfo.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }

        let scByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let orderedSCWindows = visualOrderIDs.compactMap { scByID[$0] }

        let candidates = orderedSCWindows.map(makeCandidate)
        let allowedIDs = Set(filterPickerCandidates(candidates, ownPID: ownPID).map(\.windowID))
        return orderedSCWindows.filter { allowedIDs.contains($0.windowID) }
    }

    /// Same ordering/filtering as `candidates(in:ownPID:)` but returns the value
    /// types (with bundle ID + PID) the strategy selector needs.
    static func candidateValues(in content: SCShareableContent, ownPID: pid_t) -> [WindowCandidate] {
        let allowed = candidates(in: content, ownPID: ownPID)
        return allowed.map(makeCandidate)
    }

    /// Converts an SCWindow to a WindowCandidate value type.
    private static func makeCandidate(_ w: SCWindow) -> WindowCandidate {
        WindowCandidate(
            windowID: w.windowID,
            owningPID: w.owningApplication?.processID ?? 0,
            owningBundleID: w.owningApplication?.bundleIdentifier,
            isOnScreen: w.isOnScreen,
            windowLayer: w.windowLayer,
            frame: w.frame)
    }
}
