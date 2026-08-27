import AppKit
import ScreenCaptureKit

/// Shared `NSScreen → CGDirectDisplayID → SCDisplay` resolution, used by both
/// full-screen image capture and recording so the matching logic lives in one
/// place. The generic `first(matching:in:)` keeps the core unit-testable without a
/// real `SCDisplay`.
enum DisplayResolver {

    /// The `CGDirectDisplayID` backing an `NSScreen` (via `NSScreenNumber`).
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The `SCDisplay` whose `displayID` equals `displayID`, if present.
    static func match(displayID: CGDirectDisplayID, in displays: [SCDisplay]) -> SCDisplay? {
        first(matching: displayID, in: displays.map { ($0.displayID, $0) })
    }

    /// Generic id-match — the element whose paired id equals `id`, else nil.
    static func first<T>(matching id: CGDirectDisplayID, in pairs: [(CGDirectDisplayID, T)]) -> T? {
        pairs.first(where: { $0.0 == id })?.1
    }
}
