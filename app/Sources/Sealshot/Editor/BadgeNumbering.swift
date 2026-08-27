import Foundation

/// The 1-based number shown on a badge: its position among all `.badge`
/// annotations in document order. Returns nil if `id` is not a badge.
/// Not stored on the annotation, so create / delete / undo / paste renumber
/// automatically. Shared by the live canvas and the export renderer.
func badgeNumber(for id: UUID, in annotations: [Annotation]) -> Int? {
    var n = 0
    for a in annotations {
        if case .badge = a.geometry {
            n += 1
            if a.id == id { return n }
        }
    }
    return nil
}
