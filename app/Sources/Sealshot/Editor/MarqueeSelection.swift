import Foundation
import CoreGraphics

/// Pure geometry for rubber-band (marquee) selection, shared by the AppKit
/// recent strip and the SwiftUI Library grid. No UI dependencies, so it can
/// be unit-tested in isolation; the two stacks only differ in how they
/// capture item frames and draw the band.
enum MarqueeSelection {

    /// Smallest drag distance (points) before a marquee starts — below this a
    /// press-and-release on empty space stays a harmless click.
    static let minDragDistance: CGFloat = 4

    /// Normalize two drag points (anchor + current) into a rect, regardless of
    /// drag direction (up-left, down-right, …).
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Whether two points are at least `minDragDistance` apart — the gate for
    /// starting a marquee.
    static func exceedsDragThreshold(_ a: CGPoint, _ b: CGPoint) -> Bool {
        hypot(a.x - b.x, a.y - b.y) >= minDragDistance
    }

    /// Every URL whose frame intersects the band — "touch = select".
    static func touched(rect: CGRect, frames: [URL: CGRect]) -> Set<URL> {
        var hit: Set<URL> = []
        for (url, frame) in frames where frame.intersects(rect) {
            hit.insert(url)
        }
        return hit
    }

    /// Combine the touched set with the base selection captured at drag start:
    /// empty for a plain drag (replace), the prior selection for a ⌘/⇧ drag
    /// (add to existing).
    static func combine(touched: Set<URL>, base: Set<URL>) -> Set<URL> {
        touched.union(base)
    }
}
