import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Generates capture title/category/tags with the on-device Foundation Model
/// via guided generation. Available only on macOS 26+; the coordinator gates on
/// `AIAvailability` and falls back to `RuleBasedMetadataGenerator` otherwise.
/// Any model error also falls back, so capture metadata is never lost.
@available(macOS 26, *)
struct FoundationMetadataGenerator: MetadataGenerating {
    /// FM generators use 100+ so the stored `generatorVersion` distinguishes
    /// model-produced metadata from rule-based (version 2).
    static let version = 100

    /// The structured value the model fills in (guided generation).
    @Generable
    struct Output {
        @Guide(description: "A concise, specific title for the screenshot, at most 8 words.")
        let title: String
        @Guide(description: "Exactly one of: error, code, design, document, dashboard, chat, settings, receipt, other.")
        let category: String
        @Guide(description: "Two to five short lowercase topic tags.")
        let tags: [String]
    }

    let maxOCRChars: Int
    init(maxOCRChars: Int = 4_000) { self.maxOCRChars = maxOCRChars }

    func makeMetadata(for signals: MetadataSignals) async -> CaptureMetadata {
        let prompt = MetadataPromptBuilder.userPrompt(from: signals, maxOCRChars: maxOCRChars)
        do {
            let session = LanguageModelSession(instructions: MetadataPromptBuilder.instructions)
            let response = try await session.respond(to: prompt, generating: Output.self)
            let out = response.content
            return captureMetadata(generatedTitle: out.title,
                                   categoryRaw: out.category,
                                   tags: out.tags,
                                   confidence: 0.9,
                                   version: Self.version)
        } catch {
            return RuleBasedMetadataGenerator().generate(signals)
        }
    }
}
#endif
