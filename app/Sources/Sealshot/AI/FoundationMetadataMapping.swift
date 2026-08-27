import Foundation

/// Maps a model's raw category string onto our closed category set. Unknown or
/// empty strings fall back to `.other`. Case/whitespace tolerant.
func screenshotCategory(fromModel raw: String) -> ScreenshotCategory {
    let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return ScreenshotCategory(rawValue: key) ?? .other
}

/// Builds `CaptureMetadata` from the model's raw fields, reusing the existing
/// tag normalizer and clamping confidence to [0,1]. Pure — no model dependency,
/// so it's testable on any OS.
func captureMetadata(generatedTitle: String,
                     categoryRaw: String,
                     tags: [String],
                     confidence: Double,
                     version: Int) -> CaptureMetadata {
    CaptureMetadata(
        generatedTitle: generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
        userTitle: nil,
        tags: [],
        smartKeywords: TagNormalizer.normalize(tags),
        category: screenshotCategory(fromModel: categoryRaw),
        confidence: min(max(confidence, 0), 1),
        generatorVersion: version
    )
}
