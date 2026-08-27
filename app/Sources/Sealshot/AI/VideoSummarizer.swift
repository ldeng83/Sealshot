import AVFoundation
import CoreGraphics
import Foundation

/// Headless video summary: decrypt the `.seal` payload → sample frames → OCR each
/// → aggregate → on-device Foundation Model (bulleted, via `infoSummary`). Returns
/// an `AIGenerationOutcome`: `.text` (usable summary), `.skip` (no readable text /
/// unsummarizable / model declined — terminal, don't retry), or `.transient`
/// (decrypt failed / FM unavailable — retry later). Cooperatively cancellable
/// (per-frame `Task.isCancelled`). Heavy lifting reuses the tested `VideoSummary`.
///
/// `@MainActor`: obtaining the decrypting `AVAsset` goes through `AVPlayer` /
/// `SealedRecordingPlayer` (main-actor); the pipeline is await-heavy, so it yields
/// the main actor between frames rather than blocking it.
/// One video metadata pass produces both the summary and the tags from a single
/// frame traversal (frames are expensive to extract, so share them).
struct VideoMetadataResult {
    /// Summary outcome (`.text` persists, `.skip` writes the empty terminal
    /// marker, `.transient` retries later).
    let summary: AIGenerationOutcome
    /// Final merged tag list (≤8), with user `existing` tags preserved.
    let tags: [String]
}

@MainActor
enum VideoSummarizer {

    /// Bumped when the video summarizer/prompt changes so summaries re-generate.
    static let summaryVersion = 1

    /// Recognition policy for the sampled frames.
    ///
    /// `.budgeted`, not the `recognize` default of `.full`: this pass runs
    /// automatically after a recording is saved, with nobody waiting on it, and
    /// it OCRs up to 24 frames (`VideoSummary.frameCount`). An unbudgeted pass
    /// multiplies the per-image worst case — 40 refine lines × 2 crop variants,
    /// ~120ms per request on a Mac with no Neural Engine — by the frame count.
    /// `.budgeted` caps that at 8 lines and one variant there, and drops the
    /// second variant everywhere.
    ///
    /// The summary half of this work is already impossible without Foundation
    /// Models, but the TAG half is gated on the AI toggle alone, so this loop
    /// does run on machines with no Neural Engine.
    /// `nonisolated`: an immutable policy constant, readable without hopping to
    /// the main actor (the enum is `@MainActor` for the generation work).
    nonisolated static let framePolicy: RefinementPolicy = .budgeted

    /// One pass: sample frames once, then derive both the summary and the tags.
    /// `onProgress` reports the frame-sampling fraction (0→1) for the bar.
    static func summarize(videoSeal: URL,
                          onProgress: (@MainActor (Double) -> Void)? = nil) async -> VideoMetadataResult {
        let manifest = try? SealMetadataStore.readManifest(at: videoSeal)
        let hasAudio = manifest?.video?.hasAudio
        // Read prior auto-keywords (not user tags) so regeneration unions within the
        // smartKeywords bucket and never touches metadata.tags (user video tags).
        let existing = manifest?.metadata?.smartKeywords ?? []

        // Decrypt failure (e.g. still locked) is transient — retry once unlocked;
        // leave tags as-is.
        guard let contents = try? VideoSealPackageIO.read(
            at: videoSeal, crypto: SealPackageCryptoContext.current()) else {
            return VideoMetadataResult(summary: .transient, tags: existing)
        }

        // Decrypting AVAsset for encrypted payloads (via SealedRecordingPlayer's
        // resource-loader-backed player item); plain AVURLAsset otherwise. Hold the
        // player alive until the pass finishes so the loader stays attached.
        let asset: AVAsset
        let player: SealedRecordingPlayer?
        // A container payload plays through a resource loader whose delegate
        // is held weakly — retained here for the pass's duration.
        var payloadLoader: AnyObject?
        if let key = contents.key {
            guard let p = try? SealedRecordingPlayer(payload: contents.payload, key: key),
                  let a = p.player.currentItem?.asset else {
                return VideoMetadataResult(summary: .transient, tags: existing)
            }
            player = p
            asset = a
        } else {
            player = nil
            let built = contents.plaintextPlaybackAsset()
            asset = built.asset
            payloadLoader = built.retain
        }

        let result = await generate(from: asset, hasAudio: hasAudio,
                                    existing: existing, onProgress: onProgress)
        _ = payloadLoader   // held until the pass is done
        // Tear the decrypting player down so its decode pipeline / resource loader
        // is released promptly (this runs over many videos — see the leak fix).
        player?.player.pause()
        player?.player.replaceCurrentItem(with: nil)
        withExtendedLifetime(player) {}
        return result
    }

    private static func generate(from asset: AVAsset, hasAudio: Bool?, existing: [String],
                                 onProgress: (@MainActor (Double) -> Void)?) async -> VideoMetadataResult {
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        // Adaptive sampling: frame count scales sub-linearly with length
        // (√duration, 4–24), spread across the whole video, keeping OCR light.
        let times = VideoSummary.sampleTimes(durationSeconds: duration)
        guard !times.isEmpty else {
            // No frames: still tag recording attributes (+ keep user tags).
            let tags = await VideoTagBuilder.assemble(
                ocrText: "", structural: [], hasAudio: hasAudio, existing: existing)
            return VideoMetadataResult(summary: .skip, tags: tags)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.75, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.75, preferredTimescale: 600)
        // Release the generator's internal frame cache when we're done (avoids
        // compounding memory across a many-video run).
        defer { generator.cancelAllCGImageGeneration() }
        let recognizer = TextRecognizer()
        let visionTagger = VisionTagger()

        var frames: [VideoSummary.FrameText] = []
        var structural = Set<String>()
        for (i, t) in times.enumerated() {
            if Task.isCancelled { return VideoMetadataResult(summary: .transient, tags: existing) }
            let cm = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? await generator.image(at: cm).image {
                // Structural tags unioned across frames (a face/QR anywhere counts).
                structural.formUnion(visionTagger.tags(for: cg).structural)
                if let layout = try? await recognizer.recognize(cg, policy: framePolicy) {
                    frames.append(.init(timeSeconds: t,
                                        text: layout.lines.map(\.text).joined(separator: "\n")))
                }
            }
            if let onProgress {
                let frac = Double(i + 1) / Double(times.count)
                await MainActor.run { onProgress(frac) }
            }
        }
        let deduped = VideoSummary.dedupe(frames)
        let ocrText = deduped.isEmpty ? "" : VideoSummary.aggregate(deduped)

        // Tags are computed regardless of summary outcome — structural/attribute
        // tags apply even when there's no readable text or FM is unavailable.
        let tags = await VideoTagBuilder.assemble(
            ocrText: ocrText, structural: structural.sorted(),
            hasAudio: hasAudio, existing: existing)

        let summary = await summaryOutcome(ocrText: ocrText, hasText: !deduped.isEmpty)
        return VideoMetadataResult(summary: summary, tags: tags)
    }

    /// Summary outcome from the aggregated OCR (same rules as before): no text or
    /// sparse "label soup" → terminal `.skip`; otherwise the FM result.
    private static func summaryOutcome(ocrText: String, hasText: Bool) async -> AIGenerationOutcome {
        guard hasText else { return .skip }
        guard SummaryCoherence.isSummarizable(ocrText) else { return .skip }
        if #available(macOS 26, *) {
            switch await FoundationTextActions().infoSummary(ocrText: ocrText) {
            case .text(let raw):
                if let clamped = SummaryClamp.clamp(raw) { return .text(clamped) }
                return .skip
            case .skip:      return .skip
            case .transient: return .transient
            }
        }
        return .transient
    }
}
