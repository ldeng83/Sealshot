import AppKit

/// The editor toolbar's delayed-capture button. It reuses `GroupedToolPillView`'s
/// body-click + chevron/long-press-to-open-a-chooser behavior, but is a distinct
/// type so it isn't conflated with the drawing *tool* groups (Line/Arrow,
/// Rectangle/Ellipse): the body starts a countdown-then-capture and the chevron
/// chooses the delay (3/5/10/15s).
final class DelayedCapturePill: GroupedToolPillView {
    // The 18pt timer glyph reaches lower than the 14pt tool icons; drop the
    // chevron further so they don't collide.
    override var chevronDownNudge: CGFloat { 4 }
}
