import CoreGraphics

/// Pure decision logic for the unified-capture overlay's click-vs-drag gesture.
/// See `UnifiedGestureTests`.
enum UnifiedGesture {
    /// A press becomes an area selection once the cursor moves at least this
    /// many points from where the mouse went down; below it, the press is a
    /// click that captures the highlighted window.
    static let dragThreshold: CGFloat = 5

    /// True once a drag has moved far enough to be an area selection.
    static func isAreaDrag(from down: CGPoint, to current: CGPoint,
                           threshold: CGFloat = dragThreshold) -> Bool {
        hypot(current.x - down.x, current.y - down.y) >= threshold
    }

    enum Outcome: Equatable {
        case region   // committed an area selection
        case window   // clicked the highlighted window
        case none     // clicked empty desktop (no window) without dragging
    }

    /// What a completed gesture means: a drag that entered area mode is a
    /// region; otherwise a click captures the highlighted window, or does
    /// nothing if there was none.
    static func outcome(enteredAreaMode: Bool, hasHighlightedWindow: Bool) -> Outcome {
        if enteredAreaMode { return .region }
        return hasHighlightedWindow ? .window : .none
    }
}
