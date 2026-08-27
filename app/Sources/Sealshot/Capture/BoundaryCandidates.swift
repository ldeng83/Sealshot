import CoreGraphics

/// The merged hover-candidate set for one frozen display: detected boundary
/// rects plus window frames, all in view-local coordinates. `stack(at:)`
/// returns every candidate containing a point, smallest first — the overlay
/// highlights the first and the scroll wheel walks outward through the rest.
/// Pure and order-stable so cycling is deterministic.
struct BoundaryCandidates {

    struct Candidate: Equatable {
        enum Kind: Equatable {
            case boundary
            case window(UInt32)   // CGWindowID
        }
        let kind: Kind
        let rect: CGRect
    }

    private let boundaries: [Candidate]
    private let windows: [Candidate]

    init(boundaryRects: [CGRect], windowRects: [(UInt32, CGRect)]) {
        boundaries = boundaryRects
            .map { Candidate(kind: .boundary, rect: $0) }
            .sorted { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        windows = windowRects.map { Candidate(kind: .window($0.0), rect: $0.1) }
    }

    /// Candidates containing `point`: boundaries smallest-first, then windows
    /// (a window is always the outermost sensible target). Top-bar strips
    /// (tab/menu/toolbars) are demoted below their container, so hovering a
    /// browser's tab bar highlights the whole window first — the strip stays
    /// reachable by scroll-cycling.
    func stack(at point: CGPoint) -> [Candidate] {
        var stack = boundaries.filter { $0.rect.contains(point) }
            + windows.filter { $0.rect.contains(point) }

        // Demote each top-bar strip to just after the first later (larger)
        // candidate it is a strip OF. Each move pushes an element strictly
        // later, so the loop terminates.
        var i = 0
        while i < stack.count {
            let cand = stack[i]
            guard cand.kind == .boundary,
                  let j = ((i + 1)..<stack.count).first(where: {
                      Self.isTopBar(cand.rect, of: stack[$0].rect)
                  })
            else { i += 1; continue }
            stack.remove(at: i)
            stack.insert(cand, at: j)   // index j is "after the container" post-removal
        }
        return stack
    }

    /// Detection serves window/app-scale areas only: drop fine-grained
    /// elements (buttons, cards, tab bars, sidebars) so hovering highlights a
    /// window-like region — the smallest plausible "app area" being roughly a
    /// dialog. The detected area is captured as-is from the frozen frame
    /// (WYSIWYG), so what highlights is exactly what's grabbed.
    static func windowScaleRects(_ rects: [CGRect]) -> [CGRect] {
        rects.filter { $0.width >= 240 && $0.height >= 160 }
    }

    /// A "top bar": wide relative to its container, short, and flush with the
    /// container's top edge (view-local bottom-left coords → top is maxY).
    /// Catches title/tab/tool bars without demoting buttons (too narrow),
    /// list rows (not at the top), or real top panes (too tall).
    static func isTopBar(_ rect: CGRect, of container: CGRect) -> Bool {
        guard container.width > 0, container.height > 0 else { return false }
        return rect.width >= 0.7 * container.width
            && rect.height <= 0.2 * container.height
            && rect.height <= 160
            && (container.maxY - rect.maxY) <= 12
    }
}
