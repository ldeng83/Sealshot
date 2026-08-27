import Foundation

/// Async metadata generation, so the rule-based (sync) and Foundation Model
/// (async) generators share one interface the coordinator can `await`.
protocol MetadataGenerating {
    func makeMetadata(for signals: MetadataSignals) async -> CaptureMetadata
}

/// The deterministic rule-based generator is the always-available fallback.
extension RuleBasedMetadataGenerator: MetadataGenerating {
    func makeMetadata(for signals: MetadataSignals) async -> CaptureMetadata {
        generate(signals)
    }
}

/// Which generator to run for a capture.
enum MetadataGeneratorChoice: Equatable {
    case foundationModel
    case ruleBased
}

/// Prefer the on-device Foundation Model only when the user has AI enabled AND
/// the model is actually available on this machine; otherwise fall back to the
/// deterministic rule-based generator.
func chooseMetadataGenerator(aiEnabled: Bool, foundationModelAvailable: Bool) -> MetadataGeneratorChoice {
    (aiEnabled && foundationModelAvailable) ? .foundationModel : .ruleBased
}
