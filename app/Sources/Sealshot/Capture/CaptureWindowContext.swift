import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One on-screen window, normalised into AppKit-global coordinates, with the
/// flags `bestWindow` needs to judge eligibility. Pure value — no ScreenCaptureKit.
struct WindowDescriptor: Equatable {
    let frame: CGRect
    let title: String?
    let appName: String?
    let isOwnApp: Bool
    let isOnScreen: Bool
    let isNormalLayer: Bool
}

/// Pick the window a capture most likely belongs to: the eligible window with
/// the greatest area overlapping `reference`, breaking ties toward the frontmost
/// app and then the larger window. Returns nil when nothing eligible overlaps.
///
/// Eligible = on-screen, normal layer, and not one of Sealshot's own windows
/// (so the selection overlay / editor never titles a capture).
func bestWindow(reference: CGRect, candidates: [WindowDescriptor]) -> WindowDescriptor? {
    // Eligible windows in front-to-back order (ScreenCaptureKit z-order).
    let eligible = candidates.filter { $0.isOnScreen && $0.isNormalLayer && !$0.isOwnApp }

    // Rank by *visible* area within the selection, not raw frame overlap: each
    // window's contribution is its selection-overlap minus the parts already
    // covered by windows in front of it. An occluded background window (a
    // maximized browser behind a terminal, or Music behind a browser) thus
    // contributes ~0 and can't steal the capture from what's actually on top.
    var best: (window: WindowDescriptor, visible: CGFloat)?
    for (i, w) in eligible.enumerated() {
        let sel = w.frame.intersection(reference)
        guard !sel.isNull else { continue }
        var visible = area(sel)
        for closer in eligible[0..<i] {            // windows in front of `w`
            visible -= overlapArea(sel, closer.frame)
        }
        visible = max(0, visible)
        if visible > 0, best == nil || visible > best!.visible {
            best = (w, visible)
        }
    }
    return best?.window
}

/// Convert a Quartz-global rect (top-left origin, y grows downward) to
/// AppKit-global (bottom-left origin, y grows upward). `primaryHeight` is the
/// height of the primary display (`NSScreen.screens[0].frame.height`), the
/// anchor both coordinate systems share.
func quartzToAppKit(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.origin.x,
           y: primaryHeight - (rect.origin.y + rect.height),
           width: rect.width, height: rect.height)
}

private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let r = a.intersection(b)
    return r.isNull ? 0 : area(r)
}

private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

/// Resolves the `(app, title)` to attribute to a region/fullscreen capture by
/// asking ScreenCaptureKit for the current windows and running `bestWindow`.
/// Thin glue over the pure core above.
enum CaptureWindowContext {

    /// `reference` is the capture's region (or the display's frame for
    /// fullscreen) in AppKit-global coordinates. Returns `(nil, nil)` when the
    /// window list can't be read or nothing eligible overlaps.
    @MainActor
    static func resolve(reference: CGRect) async -> (app: String?, title: String?) {
        guard let content = try? await SCShareableContent.current else { return (nil, nil) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownBundleID = Bundle.main.bundleIdentifier

        // `SCShareableContent.windows` is NOT in z-order. Get the real
        // front-to-back order from the window server (CGWindowList is documented
        // front-to-back) and sort by it, so occlusion/visible-area is correct.
        let zRank = windowServerZOrder()
        let ordered = content.windows.sorted {
            (zRank[$0.windowID] ?? Int.max) < (zRank[$1.windowID] ?? Int.max)
        }

        let candidates = ordered.map { w -> WindowDescriptor in
            let bundle = w.owningApplication?.bundleIdentifier
            return WindowDescriptor(
                frame: quartzToAppKit(w.frame, primaryHeight: primaryHeight),
                title: w.title,
                appName: w.owningApplication?.applicationName,
                isOwnApp: bundle != nil && bundle == ownBundleID,
                isOnScreen: w.isOnScreen,
                isNormalLayer: w.windowLayer == 0)
        }

        guard let best = bestWindow(reference: reference, candidates: candidates) else {
            return (nil, nil)
        }
        return (best.appName, best.title)
    }

    /// Front-to-back z-order from the window server, keyed by window number.
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)` returns windows in
    /// the window server's front-to-back order — the authoritative source
    /// (`SCShareableContent.windows` is not ordered this way).
    private static func windowServerZOrder() -> [CGWindowID: Int] {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var rank: [CGWindowID: Int] = [:]
        for (i, dict) in info.enumerated() {
            if let num = dict[kCGWindowNumber as String] as? CGWindowID { rank[num] = i }
        }
        return rank
    }
}
