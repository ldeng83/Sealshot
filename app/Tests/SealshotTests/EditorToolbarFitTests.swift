import XCTest
import AppKit
@testable import Sealshot

/// The fold decision itself — pure arithmetic, no views.
final class EditorToolbarFitTests: XCTestCase {

    private typealias Fit = EditorToolbarFit

    func testWideWindow_foldsNothing() {
        XCTAssertEqual(Fit.plan(availableWidth: 1600), [])
        // Exactly enough room is enough.
        XCTAssertEqual(Fit.plan(availableWidth: Fit.expandedWidth), [])
    }

    /// One point short and only the cheapest cluster goes — folding is
    /// proportional to the shortfall, not all-or-nothing.
    func testSlightlyNarrow_foldsOnlyTheFirstCluster() {
        XCTAssertEqual(Fit.plan(availableWidth: Fit.expandedWidth - 1), [.record])
    }

    /// Fold order is fixed: the action clusters go before any drawing tool.
    func testFoldOrder_spendsActionClustersBeforeDrawingTools() {
        let actions: Set<Fit.ClusterID> = [.record, .capture, .ai, .trailing]
        let tools: Set<Fit.ClusterID> = [.navigate, .draw, .mark]
        var seenTool = false
        for cluster in Fit.clusters {
            if tools.contains(cluster.id) { seenTool = true }
            if actions.contains(cluster.id) {
                XCTAssertFalse(seenTool, "\(cluster.id) folds after a drawing cluster")
            }
        }
    }

    /// The whole point of the feature: at the window's new minimum width the
    /// bar fits. If a pill is ever added without extending the fold plan, this
    /// is what fails.
    func testAtTheWindowMinimum_theBarFits() {
        // The bar spans the window less the sidebar, but it is the widest row
        // in the editor, so the window minimum is the honest test.
        let plan = Fit.plan(availableWidth: 560)
        XCTAssertLessThanOrEqual(Fit.width(folded: plan), 560,
                                 "the folded bar must fit the 560pt minimum window")
    }

    func testFullyFolded_isSubstantiallyNarrowerThanExpanded() {
        let all = Set(Fit.ClusterID.allCases)
        XCTAssertEqual(Fit.plan(availableWidth: 100), all,
                       "an impossible width folds everything rather than clipping")
        XCTAssertLessThan(Fit.width(folded: all), Fit.expandedWidth - 500)
    }

    /// A drag that hovers on a threshold must not rebuild the bar every frame:
    /// a folded cluster stays folded until there is real room to spare.
    func testHysteresis_holdsAFoldUntilThereIsRoomToSpare() {
        let justEnough = Fit.expandedWidth
        // Coming from folded, exactly-enough room is NOT enough to unfold.
        XCTAssertEqual(Fit.plan(availableWidth: justEnough, current: [.record]),
                       [.record])
        // With the hysteresis margin on top, it unfolds.
        XCTAssertEqual(Fit.plan(availableWidth: justEnough + Fit.hysteresis,
                                current: [.record]),
                       [])
        // Hysteresis only resists UNfolding — folding still happens at once.
        XCTAssertTrue(Fit.plan(availableWidth: justEnough - 1, current: [])
            .contains(.record))
    }

    /// Savings are derived from what each fold removes, so the width model
    /// stays consistent with `barWidth`.
    func testClusterSavings_matchTheBarWidthModel() {
        for cluster in Fit.clusters {
            let after = Fit.barWidth(pills: Fit.expandedPills - cluster.pillsRemoved,
                                     dividers: Fit.expandedDividers - cluster.dividersRemoved)
            XCTAssertEqual(Fit.expandedWidth - after, cluster.saving, accuracy: 0.001,
                           "\(cluster.id) saving disagrees with the width model")
        }
    }
}

/// Ties the arithmetic above to the bar that actually gets built. Without
/// these, adding a pill to the toolbar would silently break folding: the model
/// would keep reporting the old width and the window would clamp again.
@MainActor
final class EditorToolbarFitWidthTests: XCTestCase {

    private func measuredWidth(folded: Set<EditorToolbarFit.ClusterID>) -> CGFloat {
        let builder = EditorToolbarBuilder()
        let bar = builder.makeToolbarView(empty: false, folded: folded)
        bar.layoutSubtreeIfNeeded()
        return bar.fittingSize.width
    }

    func testExpandedWidthModel_matchesTheRealBar() {
        XCTAssertEqual(measuredWidth(folded: []), EditorToolbarFit.expandedWidth,
                       accuracy: 1,
                       "the pill/divider counts in EditorToolbarFit have drifted "
                       + "from makeToolbarView — update them together")
    }

    func testEachFoldSavesWhatTheModelClaims() {
        for cluster in EditorToolbarFit.clusters {
            XCTAssertEqual(measuredWidth(folded: [cluster.id]),
                           EditorToolbarFit.expandedWidth - cluster.saving,
                           accuracy: 1,
                           "folding \(cluster.id) doesn't save what the model says")
        }
    }

    func testFullyFoldedBar_fitsTheMinimumWindow() {
        XCTAssertLessThanOrEqual(measuredWidth(folded: Set(EditorToolbarFit.ClusterID.allCases)),
                                 560)
    }
}
