import Foundation

/// Depth operations on the annotation array (last = topmost in both render
/// pipelines). See AnnotationZOrderTests.
enum ZOrderOperation {
    case toFront, forward, backward, toBack
}

/// Reorder `annotations` so the `selected` group moves per `op`. The group
/// moves as a unit, preserving its internal relative order (so a multi-
/// selection consolidates, like standard editors). Returns the input
/// unchanged when the move is impossible (extreme reached, empty/foreign
/// selection).
func reorderAnnotations(_ annotations: [Annotation], selected: Set<UUID>,
                        _ op: ZOrderOperation) -> [Annotation] {
    let group = annotations.filter { selected.contains($0.id) }
    guard !group.isEmpty else { return annotations }
    let rest = annotations.filter { !selected.contains($0.id) }
    switch op {
    case .toBack:
        return group + rest
    case .toFront:
        return rest + group
    case .backward:
        // Step below the nearest non-selected neighbor under the group's
        // lowest member.
        guard let lowest = annotations.firstIndex(where: { selected.contains($0.id) })
        else { return annotations }
        let belowCount = annotations[..<lowest]
            .filter { !selected.contains($0.id) }.count
        guard belowCount > 0 else { return annotations }   // already at back
        var out = rest
        out.insert(contentsOf: group, at: belowCount - 1)
        return out
    case .forward:
        // Step above the nearest non-selected neighbor over the group's
        // highest member.
        guard let highest = annotations.lastIndex(where: { selected.contains($0.id) })
        else { return annotations }
        let aboveCount = annotations[(highest + 1)...]
            .filter { !selected.contains($0.id) }.count
        guard aboveCount > 0 else { return annotations }   // already at front
        var out = rest
        out.insert(contentsOf: group, at: rest.count - aboveCount + 1)
        return out
    }
}
