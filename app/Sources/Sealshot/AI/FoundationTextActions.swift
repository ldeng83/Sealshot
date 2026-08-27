import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// On-demand text actions over a capture's OCR text using the on-device
/// Foundation Model: Summarize and Extract. macOS 26+; callers gate on
/// `AIAvailability`. Returns nil on error or empty output.
@available(macOS 26, *)
struct FoundationTextActions {
    let maxOCRChars: Int
    init(maxOCRChars: Int = 4_000) { self.maxOCRChars = maxOCRChars }

    func summarize(ocrText: String) async -> AIGenerationOutcome {
        await run(instructions: AITextActionPromptBuilder.summaryInstructions, ocrText: ocrText)
    }

    /// Compact bulleted summary for the persisted Info-panel summary.
    func infoSummary(ocrText: String) async -> AIGenerationOutcome {
        await run(instructions: AITextActionPromptBuilder.infoSummaryInstructions, ocrText: ocrText)
    }

    /// One-sentence description of a single Live Capture window, for that
    /// window's bullet in a scene summary.
    func windowSummary(ocrText: String) async -> AIGenerationOutcome {
        await run(instructions: AITextActionPromptBuilder.windowSummaryInstructions, ocrText: ocrText)
    }

    /// One-shot user action: collapses the outcome to text-or-nil (no persisted
    /// retry/skip distinction needed for an interactive Extract).
    func extract(ocrText: String) async -> String? {
        if case let .text(t) = await run(
            instructions: AITextActionPromptBuilder.extractInstructions, ocrText: ocrText) {
            return t
        }
        return nil
    }

    /// Compose a unified Markdown document from the deterministic structured
    /// extraction + the raw OCR text. nil on error/empty (caller falls back).
    func composeMarkdown(structured: String, ocrText: String, hasTable: Bool) async -> String? {
        let prompt = """
        Structured extraction:
        \(structured)

        Raw text (OCR):
        \(MetadataPromptBuilder.ocrExcerpt(ocrText, maxChars: maxOCRChars))
        """
        do {
            let session = LanguageModelSession(
                instructions: AITextActionPromptBuilder.markdownComposeInstructions(hasTable: hasTable))
            let text = try await session.respond(to: prompt).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    /// Run the model and classify the result: usable text, a terminal `.skip`
    /// (empty output, or a non-retryable error like unsupported language /
    /// guardrail), or a `.transient` failure to retry later.
    private func run(instructions: String, ocrText: String) async -> AIGenerationOutcome {
        let prompt = AITextActionPromptBuilder.prompt(ocrText: ocrText, maxOCRChars: maxOCRChars)
        do {
            let session = LanguageModelSession(instructions: instructions)
            let text = try await session.respond(to: prompt).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .skip : .text(text)
        } catch {
            return AIErrorClassifier.outcome(for: error)
        }
    }
}
#endif
