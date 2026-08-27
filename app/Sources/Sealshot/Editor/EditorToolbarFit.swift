import AppKit

/// Decides which runs of the editor toolbar fold away at the current window
/// width.
///
/// The bar is ~29 fixed-width pills wide open, so its intrinsic width — not
/// the window's declared minimum — used to be what stopped the editor being
/// resized small. Rather than let pills spill or clip, whole clusters collapse
/// behind a single menu-backed pill, in a fixed priority order: the runs people
/// reach for least go first, and the drawing tools go last.
///
/// Pure arithmetic, no views: the fold decision is unit-tested rather than
/// discovered by dragging a window edge. `EditorToolbarFitWidthTests` pins the
/// model against the real bar's `fittingSize`, so a pill added to the toolbar
/// without updating the counts here fails the build rather than quietly
/// breaking the folding.
enum EditorToolbarFit {

    /// A collapsible run, in fold order.
    enum ClusterID: String, CaseIterable {
        /// Record Full Screen + Record Selection → one Record pill.
        case record
        /// Full Screen / Delayed / Scrolling / Live → the Capture pill's menu.
        case capture
        /// Smart Redact, Extract, Enhance, Cutout → one AI pill.
        case ai
        /// Find in Image, Info, Copy All → one ⋯ pill (Export stays out).
        case trailing
        /// Select + Hand → one grouped pill.
        case navigate
        /// Pen, Line, Arrow, Shape → one grouped pill.
        case draw
        /// Text + Step → one grouped pill.
        case mark
    }

    // MARK: Width model

    /// Every toolbar pill is this wide (`ActiveToolPillView.pillSize`); none of
    /// them compress, which is the whole reason folding exists.
    static let pillWidth: CGFloat = 28
    static let dividerWidth: CGFloat = 1
    static let spacing: CGFloat = 6
    /// The bar's left + right edge insets combined.
    static let edgeInsets: CGFloat = 28

    /// Width of a bar holding `pills` pills, `dividers` dividers and the two
    /// flexible centring spacers (which floor at zero width).
    static func barWidth(pills: Int, dividers: Int, spacers: Int = 2) -> CGFloat {
        let items = pills + dividers + spacers
        let gaps = max(items - 1, 0)
        return edgeInsets
            + CGFloat(pills) * pillWidth
            + CGFloat(dividers) * dividerWidth
            + CGFloat(gaps) * spacing
    }

    /// The wide-open bar: 29 pills, 5 dividers.
    static let expandedPills = 29
    static let expandedDividers = 5
    static var expandedWidth: CGFloat {
        barWidth(pills: expandedPills, dividers: expandedDividers)
    }

    /// What folding one cluster removes from the bar.
    struct Cluster: Equatable {
        let id: ClusterID
        let pillsRemoved: Int
        let dividersRemoved: Int

        /// Points freed by folding it — the pills and dividers themselves plus
        /// the inter-item gaps that disappear with them.
        var saving: CGFloat {
            let items = pillsRemoved + dividersRemoved
            return CGFloat(pillsRemoved) * pillWidth
                + CGFloat(dividersRemoved) * dividerWidth
                + CGFloat(items) * spacing
        }
    }

    /// Fold order, least-missed first. Drawing tools are what people click all
    /// day, so they trail the action clusters and fold only once the window is
    /// genuinely small.
    static let clusters: [Cluster] = [
        Cluster(id: .record, pillsRemoved: 1, dividersRemoved: 0),
        Cluster(id: .capture, pillsRemoved: 4, dividersRemoved: 1),
        Cluster(id: .ai, pillsRemoved: 3, dividersRemoved: 0),
        Cluster(id: .trailing, pillsRemoved: 2, dividersRemoved: 0),
        Cluster(id: .navigate, pillsRemoved: 1, dividersRemoved: 0),
        Cluster(id: .draw, pillsRemoved: 3, dividersRemoved: 0),
        Cluster(id: .mark, pillsRemoved: 1, dividersRemoved: 0),
    ]

    /// Width of the bar with `folded` collapsed.
    static func width(folded: Set<ClusterID>) -> CGFloat {
        clusters.filter { folded.contains($0.id) }
            .reduce(expandedWidth) { $0 - $1.saving }
    }

    /// Extra room a fold must gain back before it un-folds. Without it a drag
    /// that hovers on a threshold rebuilds the bar every frame, and the pills
    /// under the pointer flicker in and out.
    static let hysteresis: CGFloat = 24

    // MARK: The decision

    /// Which clusters are folded at `availableWidth`.
    ///
    /// `current` is what is folded right now: a cluster already folded stays
    /// folded until there is `hysteresis` more room than it strictly needs, so
    /// the bar settles instead of oscillating mid-drag.
    static func plan(availableWidth: CGFloat,
                     current: Set<ClusterID> = [],
                     hysteresis: CGFloat = hysteresis) -> Set<ClusterID> {
        let base = greedy(target: availableWidth)
        guard !current.isEmpty else { return base }
        // Un-folding needs the extra margin; folding never does.
        let sticky = greedy(target: availableWidth - hysteresis)
        return base.union(current.intersection(sticky))
    }

    /// Fold in priority order until the bar fits `target`. Folds everything if
    /// it still doesn't fit — a fully folded bar that overflows is better than
    /// pills clipped at the window edge.
    private static func greedy(target: CGFloat) -> Set<ClusterID> {
        var folded: Set<ClusterID> = []
        var width = expandedWidth
        for cluster in clusters {
            if width <= target { break }
            folded.insert(cluster.id)
            width -= cluster.saving
        }
        return folded
    }
}

/// The tool bar's container, which reports its width as Auto Layout resolves
/// it. The window's own resize notifications are the wrong signal: they fire
/// before the split view has divided the space, so the bar would fold against
/// a width it never gets. A layout pass is the first moment the real number
/// exists.
final class ToolbarFitHostView: NSView {

    /// Called on each layout pass whose width differs from the last one.
    var onWidthChange: ((CGFloat) -> Void)?

    private var reportedWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = bounds.width
        guard abs(width - reportedWidth) > 0.5 else { return }
        reportedWidth = width
        onWidthChange?(width)
    }
}
