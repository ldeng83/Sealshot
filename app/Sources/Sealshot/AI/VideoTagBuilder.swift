import Foundation

/// Assembles a recording's tags from the same sources as image tagging, but over
/// a whole video: deterministic content tags from the aggregated frame OCR,
/// structural tags unioned across sampled frames, recording attributes, and
/// (best-effort) FM topical tags. Tags are stored in `CaptureMetadata.smartKeywords`
/// (shared with images) so the Library index / search / vocabulary / chip UI all
/// work for video unchanged. Pure where it can be, for unit testing.
enum VideoTagBuilder {

    /// Bumped when video tag generation changes so recordings re-tag. Stored in
    /// `VideoInfo.tagVersion`.
    static let version = 1

    /// Deterministic content tags (category + keyword) from aggregated frame OCR,
    /// reusing the image rule-based generator with video-appropriate signals
    /// (no sourceApp/windowTitle; geometry unused for tagging).
    static func contentTags(ocrText: String) -> [String] {
        let signals = MetadataSignals(ocrText: ocrText, sourceApp: nil,
                                      windowTitle: nil, captureDate: Date(),
                                      imageWidth: 0, imageHeight: 0)
        return RuleBasedMetadataGenerator().generate(signals).smartKeywords
    }

    /// Recording attributes: always `screen-recording`, plus `has-audio` when the
    /// recording is known to carry an audio track.
    static func attributeTags(hasAudio: Bool?) -> [String] {
        var tags = ["screen-recording"]
        if hasAudio == true { tags.append("has-audio") }
        return tags
    }

    /// Merge all sources into the final ≤8 canonical list. Priority is expressed
    /// by input order (then `TagNormalizer` dedups + caps, first-seen):
    /// user/existing > structural > content > FM > attributes — so user tags are
    /// never dropped and high-precision structural tags win the cap over fuzzier
    /// content/FM/attribute tags.
    static func merge(existing: [String], structural: [String],
                      content: [String], fm: [String], attributes: [String]) -> [String] {
        TagNormalizer.normalize(existing + structural + content + fm + attributes)
    }

    /// Full assembly for a recording: deterministic content + structural (unioned
    /// across frames) + attributes, plus best-effort FM topical tags **gated on
    /// availability** (FM available + AI pref + macOS 26). FM is additive and
    /// failure-tolerant (`FoundationMetadataGenerator` falls back internally), so
    /// it never blocks tagging. Result is merged ≤8 with user `existing` first.
    static func assemble(ocrText: String, structural: [String],
                         hasAudio: Bool?, existing: [String]) async -> [String] {
        let content = contentTags(ocrText: ocrText)
        var fm: [String] = []
        #if canImport(FoundationModels)
        if #available(macOS 26, *),
           AIAvailability.isFoundationModelAvailable, AIFeaturePreference().enabled,
           !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let signals = MetadataSignals(ocrText: ocrText, sourceApp: nil, windowTitle: nil,
                                          captureDate: Date(), imageWidth: 0, imageHeight: 0)
            fm = await FoundationMetadataGenerator().makeMetadata(for: signals).smartKeywords
        }
        #endif
        return merge(existing: existing, structural: structural,
                     content: content, fm: fm, attributes: attributeTags(hasAudio: hasAudio))
    }
}
