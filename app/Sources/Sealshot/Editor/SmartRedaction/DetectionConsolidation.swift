import CoreGraphics

/// Collapses the redaction proposal list: drops same-pixel redundant detections,
/// then merges same-value detections across locations. Pure.
enum DetectionConsolidation {
    /// True if `a` is the preferred representative over `b`:
    /// mapped category > .contextual, then higher confidence, then longer
    /// snippet, then a deterministic snippet tiebreak.
    static func betterDetection(_ a: Detection, _ b: Detection) -> Bool {
        let aMapped = a.category != .contextual, bMapped = b.category != .contextual
        if aMapped != bMapped { return aMapped }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        if a.snippet.count != b.snippet.count { return a.snippet.count > b.snippet.count }
        return a.snippet < b.snippet
    }

    /// Normalise a snippet for identity / containment comparisons.
    static func normalized(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }

    /// Fraction of `a`'s total rect area that overlaps `b`'s rects.
    private static func coveredFraction(_ a: Detection, by b: Detection) -> CGFloat {
        let aArea = a.rects.reduce(CGFloat(0)) { $0 + max(0, $1.width) * max(0, $1.height) }
        guard aArea > 0 else { return 0 }
        var covered: CGFloat = 0
        for ar in a.rects {
            var best: CGFloat = 0
            for br in b.rects {
                let inter = ar.intersection(br)
                if !inter.isNull { best = max(best, inter.width * inter.height) }
            }
            covered += best
        }
        return covered / aArea
    }

    /// Drop a candidate ONLY when its actual rects are ≥60% covered by a kept
    /// detection's rects AND its text is a sub-fragment of that keeper's text.
    /// (Rect-level — not bbox — so a spread/multi-line detection never swallows
    /// disjoint values; substring guard — so only a true fragment is removed.)
    static func overlapResolved(_ detections: [Detection]) -> [Detection] {
        let sorted = detections.sorted(by: betterDetection)
        var kept: [Detection] = []
        for cand in sorted {
            let candKey = normalized(cand.snippet)
            let redundant = !cand.rects.isEmpty && kept.contains { k in
                coveredFraction(cand, by: k) >= 0.6 && normalized(k.snippet).contains(candKey)
            }
            if !redundant { kept.append(cand) }
        }
        return kept
    }

    /// Merge detections sharing a normalized snippet into one detection that
    /// unions all rects and adopts the best member's label/category.
    static func valueGrouped(_ detections: [Detection]) -> [Detection] {
        var order: [String] = []
        var groups: [String: [Detection]] = [:]
        for d in detections {
            let key = normalized(d.snippet)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(d)
        }
        return order.map { key in
            let group = groups[key]!
            let best = group.sorted(by: betterDetection).first!
            return Detection(
                category: best.category,
                snippet: best.snippet,
                confidence: group.map(\.confidence).max() ?? best.confidence,
                rects: DetectionGeometry.mergedRects(group.flatMap(\.rects)),
                customLabel: best.customLabel,
                reason: best.reason)
        }
    }

    private static func totalArea(_ d: Detection) -> CGFloat {
        d.rects.reduce(CGFloat(0)) { $0 + max(0, $1.width) * max(0, $1.height) }
    }

    /// Like `coveredFraction` but sums coverage across ALL of `b`'s rects per
    /// rect of `a` (not the single best). Needed for containment: one wide rect
    /// of `a` may be covered by several smaller rects of `b` (a 2-group-wide card
    /// box covered by two single-group boxes).
    private static func unionCoveredFraction(_ a: Detection, by b: Detection) -> CGFloat {
        let aArea = a.rects.reduce(CGFloat(0)) { $0 + max(0, $1.width) * max(0, $1.height) }
        guard aArea > 0 else { return 0 }
        var covered: CGFloat = 0
        for ar in a.rects {
            var cov: CGFloat = 0
            for br in b.rects {
                let inter = ar.intersection(br)
                if !inter.isNull { cov += inter.width * inter.height }
            }
            covered += min(cov, ar.width * ar.height)   // clamp (b rects may overlap)
        }
        return covered / aArea
    }

    /// Drop a detection whose rects are ≥90% covered by another, strictly larger
    /// detection's rects — a sub-item already fully included in a bigger one (e.g.
    /// a "5322" fragment inside a full card number, regardless of text or order).
    /// Safe: the contained item adds no coverage. Rect-only — no substring/text guard.
    static func containmentResolved(_ detections: [Detection]) -> [Detection] {
        detections.enumerated().filter { i, d in
            guard !d.rects.isEmpty else { return true }
            let aArea = totalArea(d)
            return !detections.enumerated().contains { j, other in
                j != i && !other.rects.isEmpty
                    && totalArea(other) > aArea                 // keep the larger
                    && unionCoveredFraction(d, by: other) >= 0.9 // this one adds ~nothing
            }
        }.map(\.element)
    }

    /// Full pass: resolve same-pixel overlaps, merge same-value rows, then drop
    /// any item fully contained within a larger one.
    static func consolidate(_ detections: [Detection]) -> [Detection] {
        containmentResolved(valueGrouped(overlapResolved(detections)))
    }
}
