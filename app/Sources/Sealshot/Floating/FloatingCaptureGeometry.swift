import CoreGraphics

/// The three fixed sizes. Fixed rather than free-resize: a resizable panel
/// invites growing it back into the large window this feature exists to escape.
enum FloatingPanelSize: String, CaseIterable, Equatable {
    case compact, standard, strip

    var title: String {
        switch self {
        case .compact:  return "Compact"
        case .standard: return "Standard"
        case .strip:    return "Strip"
        }
    }

    /// Whether the panel shows the recent-capture strip at all. The row itself
    /// mirrors the library's newest captures (the editor strip's leftmost
    /// items, `FloatingCaptureController.shownTileCount` of them).
    var showsThumbnails: Bool { self != .compact }
}

/// Corner-snap arithmetic, kept pure so the off-by-one cases are unit tests
/// rather than drag sessions on a two-monitor desk.
enum FloatingCaptureGeometry {
    /// How close a corner has to be before the panel is pulled to it.
    static let snapThreshold: CGFloat = 28
    /// The gap left between the snapped panel and the screen edge.
    static let margin: CGFloat = 14

    /// Which edges a settled panel is parked against. `nil` on an axis means it
    /// was left free-floating there.
    struct Corner: Equatable {
        enum Horizontal { case left, right }
        enum Vertical { case bottom, top }
        var horizontal: Horizontal?
        var vertical: Vertical?

        var isCorner: Bool { horizontal != nil && vertical != nil }
    }

    /// Snap `frame` to the nearest edges of `visibleFrame`, per axis, and report
    /// which edges it ended up on.
    ///
    /// Callers MUST pass `NSScreen.visibleFrame`, not `frame`: the visible frame
    /// already excludes the menu bar and the Dock, so a snapped panel can never
    /// end up underneath either.
    ///
    /// The axes are decided INDEPENDENTLY, so dragging into a corner snaps both
    /// — the first version only appeared to snap one, because a panel shoved
    /// past a corner sits further than `threshold` from the margin on the axis
    /// it overshot. Overshoot is therefore treated as "definitely snap": once
    /// any part of the panel is outside the visible frame on an axis, it is
    /// pulled back to that margin regardless of distance. A panel dragged off
    /// the screen has to come back, however far it went.
    static func snapped(_ frame: CGRect, in visibleFrame: CGRect,
                        threshold: CGFloat = snapThreshold,
                        margin: CGFloat = margin) -> (frame: CGRect, corner: Corner) {
        var result = frame
        var corner = Corner()

        let left = visibleFrame.minX + margin
        let right = visibleFrame.maxX - margin - frame.width
        let bottom = visibleFrame.minY + margin
        let top = visibleFrame.maxY - margin - frame.height

        if frame.minX < visibleFrame.minX || abs(left - frame.minX) < threshold {
            result.origin.x = left
            corner.horizontal = .left
        } else if frame.maxX > visibleFrame.maxX || abs(right - frame.minX) < threshold {
            result.origin.x = right
            corner.horizontal = .right
        }

        if frame.minY < visibleFrame.minY || abs(bottom - frame.minY) < threshold {
            result.origin.y = bottom
            corner.vertical = .bottom
        } else if frame.maxY > visibleFrame.maxY || abs(top - frame.minY) < threshold {
            result.origin.y = top
            corner.vertical = .top
        }
        return (result, corner)
    }

    /// Where a panel of `size` sits when parked at `corner` of `visibleFrame`.
    /// Used to carry a snapped panel to the same corner of another display.
    static func origin(for corner: Corner, size: CGSize, in visibleFrame: CGRect,
                       margin: CGFloat = margin) -> CGPoint {
        var point = CGPoint(x: visibleFrame.midX - size.width / 2,
                            y: visibleFrame.midY - size.height / 2)
        switch corner.horizontal {
        case .left:  point.x = visibleFrame.minX + margin
        case .right: point.x = visibleFrame.maxX - margin - size.width
        case nil:    break
        }
        switch corner.vertical {
        case .bottom: point.y = visibleFrame.minY + margin
        case .top:    point.y = visibleFrame.maxY - margin - size.height
        case nil:     break
        }
        return point
    }
}

/// Edge-docking: drag the panel PAST a screen edge and it collapses to a thin
/// line hugging that edge. Click the line (or its chevron) to bring the panel
/// back, or pull it clearly off the edge — that drag IS the restore. A drag
/// released near an edge only re-parks the line there, so sliding it along
/// the edges can never accidentally restore.
extension FloatingCaptureGeometry {
    /// `String`-backed so the docked state survives a restart (see
    /// `FloatingCapturePositionStore.DockedState`). The raw values are
    /// persisted — don't rename them.
    enum DockEdge: String, Equatable { case left, right, top, bottom }

    /// How far past the visible frame the panel must be shoved before the
    /// gesture reads as docking. Smaller overshoots snap back — the existing
    /// corner-snap behaviour — so the two gestures stay distinct.
    static let dockTriggerOvershoot: CGFloat = 24
    static let dockedLineThickness: CGFloat = 18

    /// The restore chevron on the docked line, pointing back INTO the screen:
    /// docked left shows a right-arrow, docked bottom an up-arrow, and so on.
    static func dockedChevronSymbol(for edge: DockEdge) -> String {
        switch edge {
        case .left:   return "chevron.right"
        case .right:  return "chevron.left"
        case .bottom: return "chevron.up"
        case .top:    return "chevron.down"
        }
    }
    static let dockedLineLength: CGFloat = 64

    /// The edge this frame is docking to, or nil when it isn't past any edge
    /// far enough. Horizontal edges win ties (a corner shove docks sideways).
    static func dockEdge(for frame: CGRect, in visible: CGRect,
                         overshoot: CGFloat = dockTriggerOvershoot) -> DockEdge? {
        if frame.minX < visible.minX - overshoot { return .left }
        if frame.maxX > visible.maxX + overshoot { return .right }
        if frame.maxY > visible.maxY + overshoot { return .top }
        if frame.minY < visible.minY - overshoot { return .bottom }
        return nil
    }

    /// What releasing a drag of the docked LINE does.
    enum LineRelease: Equatable {
        /// Dropped near an edge: stay a line, parked against that edge.
        case repark(DockEdge)
        /// Pulled clearly away from every edge: the drag was the restore
        /// gesture — bring the panel back where it was dropped.
        case undock
    }

    /// How far from the nearest edge the line must be dropped before the
    /// release reads as "bring the panel back" rather than "move the line".
    /// Comfortably past the corner-snap threshold, so a sloppy slide along an
    /// edge still re-parks.
    static let undockDragDistance: CGFloat = 50

    /// Decide a line-drag release from where the line was dropped: re-park
    /// against the nearest edge (horizontal wins ties, matching `dockEdge`),
    /// or undock when it was pulled further than `undockDistance` from all of
    /// them.
    static func lineRelease(for frame: CGRect, in visible: CGRect,
                            undockDistance: CGFloat = undockDragDistance) -> LineRelease {
        let nearest = nearestEdge(for: frame, in: visible)
        return nearest.distance > undockDistance ? .undock : .repark(nearest.edge)
    }

    /// The edge `frame`'s centre is closest to, and how far away it is.
    /// Horizontal edges win ties, matching `dockEdge`.
    static func nearestEdge(for frame: CGRect,
                            in visible: CGRect) -> (edge: DockEdge, distance: CGFloat) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let distances: [(DockEdge, CGFloat)] = [
            (.left, center.x - visible.minX),
            (.right, visible.maxX - center.x),
            (.bottom, center.y - visible.minY),
            (.top, visible.maxY - center.y),
        ]
        let nearest = distances.min(by: { $0.1 < $1.1 })!
        return (nearest.0, nearest.1)
    }

    /// The thin line's frame: hugging `edge` just inside the visible frame,
    /// centred where the panel was along that edge, clamped fully on-screen.
    static func dockedLineFrame(edge: DockEdge, near frame: CGRect,
                                in visible: CGRect) -> CGRect {
        let t = dockedLineThickness, l = dockedLineLength
        switch edge {
        case .left, .right:
            let y = min(max(frame.midY - l / 2, visible.minY), visible.maxY - l)
            let x = edge == .left ? visible.minX : visible.maxX - t
            return CGRect(x: x, y: y, width: t, height: l)
        case .top, .bottom:
            let x = min(max(frame.midX - l / 2, visible.minX), visible.maxX - l)
            let y = edge == .bottom ? visible.minY : visible.maxY - t
            return CGRect(x: x, y: y, width: l, height: t)
        }
    }

    /// The docked line carried to another display: same edge, same RELATIVE
    /// position along it, so a line two-thirds of the way down the left edge
    /// arrives two-thirds of the way down the new screen's left edge rather
    /// than at a raw coordinate that may not even exist there (displays differ
    /// in size, and their origins are arbitrary).
    static func dockedLine(_ line: CGRect, movedFrom from: CGRect,
                           to visible: CGRect, edge: DockEdge) -> CGRect {
        let t = dockedLineThickness, l = dockedLineLength
        switch edge {
        case .left, .right:
            let fraction = from.height > 0 ? (line.midY - from.minY) / from.height : 0.5
            let midY = visible.minY + fraction * visible.height
            let y = min(max(midY - l / 2, visible.minY), visible.maxY - l)
            return CGRect(x: edge == .left ? visible.minX : visible.maxX - t,
                          y: y, width: t, height: l)
        case .top, .bottom:
            let fraction = from.width > 0 ? (line.midX - from.minX) / from.width : 0.5
            let midX = visible.minX + fraction * visible.width
            let x = min(max(midX - l / 2, visible.minX), visible.maxX - l)
            return CGRect(x: x, y: edge == .bottom ? visible.minY : visible.maxY - t,
                          width: l, height: t)
        }
    }

    /// Where the restored panel goes: adjacent to the line's edge at the
    /// normal snap margin, centred on the line, clamped inside the screen.
    static func restoredFrame(from line: CGRect, edge: DockEdge, size: CGSize,
                              in visible: CGRect,
                              margin: CGFloat = margin) -> CGRect {
        var origin: CGPoint
        switch edge {
        case .left:
            origin = CGPoint(x: visible.minX + margin, y: line.midY - size.height / 2)
        case .right:
            origin = CGPoint(x: visible.maxX - margin - size.width, y: line.midY - size.height / 2)
        case .bottom:
            origin = CGPoint(x: line.midX - size.width / 2, y: visible.minY + margin)
        case .top:
            origin = CGPoint(x: line.midX - size.width / 2, y: visible.maxY - margin - size.height)
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - margin - size.width)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - margin - size.height)
        return CGRect(origin: origin, size: size)
    }
}
