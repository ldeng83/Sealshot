import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Expands a natural-language Library search into related keywords using the
/// on-device Foundation Model. macOS 26+; callers gate on `AIAvailability`.
/// Returns [] on error (the caller then runs a plain literal search).
@available(macOS 26, *)
struct FoundationSearchExpander {
    @Generable
    struct Output {
        @Guide(description: "5 to 12 search keywords: the original words, close synonyms, and related terms like error codes. Lowercase single words.")
        let terms: [String]
    }

    func expand(query: String) async -> [String] {
        do {
            let session = LanguageModelSession(instructions: SearchQueryPromptBuilder.instructions)
            let out = try await session.respond(
                to: SearchQueryPromptBuilder.prompt(query: query), generating: Output.self).content
            return out.terms
        } catch {
            return []
        }
    }
}
#endif
