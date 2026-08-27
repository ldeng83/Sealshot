import CoreGraphics

/// Plain value-type view of an NSScreen's frame, sufficient for hit-testing
/// the cursor against display bounds. Tests use this directly; the call site
/// in CaptureCoordinator maps `[NSScreen] -> [DisplayBounds]`.
struct DisplayBounds: Equatable {
    let id: Int
    let frame: CGRect
}

/// Returns the display containing `point`, or nil if no display contains it.
/// `point` is in AppKit global coordinates (bottom-left origin).
/// Pure function — see CursorDisplayTests.
internal func displayContainingPoint(
    _ point: CGPoint,
    in displays: [DisplayBounds]
) -> DisplayBounds? {
    displays.first(where: { $0.frame.contains(point) })
}
