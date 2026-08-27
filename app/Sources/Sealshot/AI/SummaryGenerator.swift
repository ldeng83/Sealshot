import Foundation

/// Produces a short on-device summary of a capture's OCR text. Behind a protocol
/// so the metadata pipeline can inject a stub in tests. Returns an
/// `AIGenerationOutcome` so callers persist a terminal marker on `.skip` and
/// leave `.transient` failures for a later retry.
protocol SummaryGenerating {
    func summarize(ocrText: String) async -> AIGenerationOutcome
}

/// Foundation-Models-backed summary. Never throws — generation must not block the
/// pipeline; failures surface as `.skip` (terminal) or `.transient`.
struct FoundationSummaryGenerator: SummaryGenerating {
    func summarize(ocrText: String) async -> AIGenerationOutcome {
        // "Label soup" screenshots (maps/dashboards) are disconnected fragments the
        // model can't summarize — skip the model entirely (terminal) so the panel
        // shows "No summary" and we don't retry.
        guard SummaryCoherence.isSummarizable(ocrText) else { return .skip }
        if #available(macOS 26, *) {
            switch await FoundationTextActions().summarize(ocrText: ocrText) {
            case .text(let raw):
                // Hard-bound the output so a runaway list can't persist; an empty
                // clamp result is terminal.
                if let clamped = SummaryClamp.clamp(raw) { return .text(clamped) }
                return .skip
            case .skip:      return .skip
            case .transient: return .transient
            }
        }
        return .transient
    }
}

/// Pure decision for whether a capture's summary should be generated now. Kept
/// separate from the generator so both the pipeline (whether to run + post
/// progress) and tests can use it without touching Foundation Models.
enum SummaryGating {
    /// Live Capture is exempt from the empty-OCR-text refusal below. For a
    /// scene, `ocrText` is `SceneText.aggregate`'s per-window text — for a
    /// desktop of photo viewers, video players, or windows whose assets
    /// failed to decode, that is legitimately `""`, not "nothing to
    /// summarize". The scene branch in `MetadataCoordinator.generateSummary`
    /// never reads this `ocrText` anyway: it rebuilds one bullet per window
    /// straight from the manifest's `sceneLayers` via `SceneSummarizer`, so a
    /// name-only list is still worth generating even with no text in hand.
    /// The exemption is deliberately scoped to scenes: widening it would let
    /// an ordinary pure image (no scene to fall back on) get "summarized"
    /// with nothing to summarize. Mirrors
    /// `MetadataCoordinator.needsTagBackfill`'s `isScene` exemption for the
    /// same shape of problem.
    static func shouldGenerate(aiEnabled: Bool, foundationModelAvailable: Bool,
                               summaryPresent: Bool, ocrText: String?,
                               userSummaryPresent: Bool = false,
                               isScene: Bool = false) -> Bool {
        // A manual override (v13) makes generation pointless — the user's
        // text wins in the display either way.
        guard aiEnabled, foundationModelAvailable, !summaryPresent, !userSummaryPresent
        else { return false }
        if isScene { return true }
        let trimmed = (ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }
}
