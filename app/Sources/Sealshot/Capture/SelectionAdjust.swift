import CoreGraphics

/// Pure geometry for the adjustable area-selection overlay: handle layout,
/// hit-testing, resize/move math, the seeded fallback box, and the confirm/
/// cancel control-bar placement. AppKit non-flipped coordinates (origin
/// bottom-left, y increases upward) — so "top" is `maxY`. No AppKit, no state:
/// this drives both the view's drawing and its event handling and is unit-tested
/// in isolation.
enum SelectionAdjust {

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, interior
    }

    /// Side length of the ✓/✕ control buttons.
    static let controlButtonSize: CGFloat = 28
    /// Gap between the buttons and from the selection edge.
    static let controlGap: CGFloat = 8

    /// Center of each resize handle (`.interior` has none).
    private static func handlePoint(_ handle: Handle, in rect: CGRect) -> CGPoint? {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .interior:    return nil
        }
    }

    /// The grab square for each resize handle, side `size`, centered on its point.
    static func handleRects(for rect: CGRect, size: CGFloat) -> [Handle: CGRect] {
        var result: [Handle: CGRect] = [:]
        for handle in Handle.allCases {
            guard let p = handlePoint(handle, in: rect) else { continue }
            result[handle] = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        }
        return result
    }

    /// Which handle (or `.interior`) a point falls on; nil if outside both.
    /// Resize handles win over the interior; corners win over edges on overlap.
    static func hitTest(_ point: CGPoint, in rect: CGRect, handleSize: CGFloat) -> Handle? {
        let rects = handleRects(for: rect, size: handleSize)
        let order: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight, .top, .right, .bottom, .left]
        for handle in order {
            if let r = rects[handle], r.contains(point) { return handle }
        }
        return rect.contains(point) ? .interior : nil
    }

    /// New rect after dragging `handle` to `point`, clamped to `bounds`. A
    /// dragged edge can't cross within `minSize` of the opposite (fixed) edge.
    static func resize(_ rect: CGRect, handle: Handle, to point: CGPoint, in bounds: CGRect, minSize: CGFloat) -> CGRect {
        var left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY

        switch handle {
        case .topLeft:     left = point.x; top = point.y
        case .top:         top = point.y
        case .topRight:    right = point.x; top = point.y
        case .right:       right = point.x
        case .bottomRight: right = point.x; bottom = point.y
        case .bottom:      bottom = point.y
        case .bottomLeft:  left = point.x; bottom = point.y
        case .left:        left = point.x
        case .interior:    return rect
        }

        // Clamp dragged edges to the screen bounds.
        left = min(max(left, bounds.minX), bounds.maxX)
        right = min(max(right, bounds.minX), bounds.maxX)
        bottom = min(max(bottom, bounds.minY), bounds.maxY)
        top = min(max(top, bounds.minY), bounds.maxY)

        // Keep at least `minSize` from the fixed edge (no crossing / collapse).
        switch handle {
        case .left, .topLeft, .bottomLeft:    left = min(left, right - minSize)
        case .right, .topRight, .bottomRight: right = max(right, left + minSize)
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: bottom = min(bottom, top - minSize)
        case .top, .topLeft, .topRight:          top = max(top, bottom + minSize)
        default: break
        }

        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// Translate `rect` by `delta`, clamped so it stays fully inside `bounds`.
    static func move(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        let x = min(max(rect.minX + delta.width, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + delta.height, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// A fallback box of `size` centered on `point`, clamped into `bounds`.
    /// Used when the initial drag was too small to define a usable rectangle.
    static func seededRect(around point: CGPoint, default size: CGSize, in bounds: CGRect) -> CGRect {
        let raw = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                         width: size.width, height: size.height)
        return move(raw, by: .zero, in: bounds)
    }

    /// Resize `rect` to an exact pixel size, anchored at its top-left
    /// (`minX`, `maxY`), clamped to `bounds`, floored at `minSize` (points).
    /// Used by the editable W×H fields.
    static func resized(_ rect: CGRect, toPixelSize pixels: (width: Int, height: Int),
                        scale: CGFloat, in bounds: CGRect, minSize: CGFloat) -> CGRect {
        let target = CoordinateMath.pointSize(pixels: pixels, scale: scale)
        let left = rect.minX
        let top = rect.maxY
        let maxW = max(minSize, bounds.maxX - left)
        let maxH = max(minSize, top - bounds.minY)
        let w = min(max(target.width, minSize), maxW)
        let h = min(max(target.height, minSize), maxH)
        return CGRect(x: left, y: top - h, width: w, height: h)
    }

    /// Positions for the ✓ (capture) and ✕ (cancel) buttons: right-anchored to
    /// the selection, below it when there's room, else flipped above.
    static func controlBarRects(for rect: CGRect, in bounds: CGRect) -> (capture: CGRect, cancel: CGRect) {
        let size = controlButtonSize, gap = controlGap
        let belowY = rect.minY - gap - size
        let y = belowY >= bounds.minY ? belowY : rect.maxY + gap
        let captureX = rect.maxX - size
        let cancelX = captureX - gap - size
        return (CGRect(x: captureX, y: y, width: size, height: size),
                CGRect(x: cancelX, y: y, width: size, height: size))
    }
}
