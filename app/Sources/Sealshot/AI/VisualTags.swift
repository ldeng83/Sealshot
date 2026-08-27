import Foundation

/// Visual tags split by reliability. `structural` detectors (qr/barcode/faces/
/// document) are high-precision and ordered ahead of the fuzzier `scene`
/// classifier tags (photo/chart/map) when the 8-tag cap forces a choice.
struct VisualTags: Equatable {
    let structural: [String]
    let scene: [String]
    var all: [String] { structural + scene }
    static let none = VisualTags(structural: [], scene: [])
}

/// Merges visual tags into a capture's tag list. Both paths run the combined
/// list through `TagNormalizer` (dedup + cap 8, first-seen order), so priority
/// is expressed purely by input ordering.
enum VisualTagMerge {

    /// Capture path: no user tags exist yet. Priority: structural > generated
    /// (category/app/keyword) > scene.
    static func atCapture(generated: [String], visual: VisualTags) -> [String] {
        TagNormalizer.normalize(visual.structural + generated + visual.scene)
    }

    /// Backfill path: `existing` may include user-added tags — keep them first so
    /// the cap can never drop them. Then structural, then scene.
    static func backfill(existing: [String], visual: VisualTags) -> [String] {
        TagNormalizer.normalize(existing + visual.structural + visual.scene)
    }
}
