import CoreGraphics
import Foundation

/// Persists the editor window's last global frame (position + size, which
/// encodes the monitor) so it reopens where the user left it — and validates a
/// restored frame against the currently-connected displays so a frame saved on
/// a now-disconnected/rearranged monitor never strands the window off-screen.
enum WindowFramePreference {

    private static let key = "editorWindowFrame"

    /// The saved frame, or nil if none / degenerate.
    static func load(_ defaults: UserDefaults = .standard) -> CGRect? {
        guard let a = defaults.array(forKey: key) as? [Double], a.count == 4 else { return nil }
        let rect = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    static func store(_ frame: CGRect, _ defaults: UserDefaults = .standard) {
        defaults.set([Double(frame.minX), Double(frame.minY),
                      Double(frame.width), Double(frame.height)], forKey: key)
    }

    /// True when `frame` overlaps some connected display's visible area by
    /// enough to grab the title bar (so the window is reachable). Pure for tests.
    static func isReachable(_ frame: CGRect, on visibleScreenFrames: [CGRect]) -> Bool {
        let minVisible = CGSize(width: 120, height: 60)
        return visibleScreenFrames.contains { screen in
            let overlap = screen.intersection(frame)
            return overlap.width >= minVisible.width && overlap.height >= minVisible.height
        }
    }
}
