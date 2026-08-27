import Foundation

/// Tunable thresholds for the structural visual-tag detectors.
///
/// Scene classification (photo/chart/map) was investigated via
/// `VNClassifyImageRequest` and dropped — see `VisionTagger.tags(for:)` and the
/// task-4 calibration in the plan — so no scene thresholds live here yet. A
/// future dedicated-model scene detector can reintroduce its own config.
struct VisionTagConfig {
    /// Minimum confidence for the document-segmentation detector.
    var documentConfidence: Float

    static let current = VisionTagConfig(documentConfidence: 0.7)
}
