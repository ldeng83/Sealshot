import AppKit

/// Stable per-monitor identity, for anything that remembers WHERE something
/// was between sessions.
///
/// `NSScreen.frame` cannot serve as the key — rearranging displays changes it
/// while the monitor stays the same — and `NSScreen` itself is not stable
/// across reconnects. The display UUID survives both.
enum DisplayIdentity {
    static func id(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) else {
            // No UUID (rare, seen with some virtual displays): the raw display
            // number is still better than nothing, and is stable for as long
            // as that display stays attached.
            return "screen-\(number.uint32Value)"
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}
