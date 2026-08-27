import Foundation

/// What changed between two strip orderings. `removed`/`inserted` preserve
/// the order they appear in `old`/`new` respectively. `orderChanged` is true
/// when the URLs surviving in BOTH lists appear in a different relative
/// order — the signal that tiles must be re-arranged, not just added/removed.
struct StripDiffResult: Equatable {
    let removed: [URL]
    let inserted: [URL]
    let orderChanged: Bool
}

/// Pure URL diff driving the strip's minimal refresh: callers remove
/// `removed` tiles, create `inserted` tiles, and re-apply target order only
/// when something was inserted or `orderChanged`.
/// Inputs are assumed duplicate-free (both producers guarantee it: the index
/// is keyed by path primary key; the fallback is one directory enumeration).
func stripDiff(old: [URL], new: [URL]) -> StripDiffResult {
    let oldSet = Set(old)
    let newSet = Set(new)
    let removed = old.filter { !newSet.contains($0) }
    let inserted = new.filter { !oldSet.contains($0) }
    let oldSurvivors = old.filter { newSet.contains($0) }
    let newSurvivors = new.filter { oldSet.contains($0) }
    return StripDiffResult(
        removed: removed,
        inserted: inserted,
        orderChanged: oldSurvivors != newSurvivors)
}
