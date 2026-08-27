import ScreenCaptureKit

/// Builds display content filters that exclude Sealshot's OWN windows, so the
/// editor, capture overlay, or recording HUD never appear in a capture.
///
/// `orderOut` alone isn't enough: the window server can keep compositing a
/// just-ordered-out window for a frame or two, so a capture triggered while
/// Sealshot is frontmost can catch the editor as a faint, translucent ghost.
/// Excluding our own application at the ScreenCaptureKit filter level removes
/// it from the captured pixels regardless of `orderOut` timing.
enum SelfExcludingContentFilter {
    /// Whether a candidate running application is Sealshot itself. Pure so the
    /// exclusion decision can be unit-tested without ScreenCaptureKit.
    static func isOwn(candidateBundleID: String?, ownBundleID: String?) -> Bool {
        guard let ownBundleID, let candidateBundleID else { return false }
        return candidateBundleID == ownBundleID
    }

    /// A display filter that excludes every Sealshot application instance. Falls
    /// back to a plain display filter when our own app can't be resolved (so a
    /// capture is never blocked by a missing self-reference).
    static func display(
        _ display: SCDisplay,
        in content: SCShareableContent,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> SCContentFilter {
        let mine = content.applications.filter {
            isOwn(candidateBundleID: $0.bundleIdentifier, ownBundleID: ownBundleID)
        }
        guard !mine.isEmpty else { return SCContentFilter(display: display, excludingWindows: []) }
        return SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
    }
}
