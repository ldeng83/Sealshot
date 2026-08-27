import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// On-device Foundation Model pass over a capture's OCR text for Smart
/// Redaction: finds context-sensitive PII the rules miss and flags likely false
/// positives among the rules' hits. macOS 26+; callers gate on `AIAvailability`.
/// Any model error yields empty results, so it's purely additive — the regex
/// floor is never weakened.
@available(macOS 26, *)
struct FoundationRedactionDetector {
    @Generable
    struct Finding {
        @Guide(description: "The sensitive substring, EXACTLY as it appears in the text.")
        let text: String
        @Guide(description: "A short label for what kind of info this is, e.g. 'Confirmation code', 'Passport number', 'Account number'.")
        let type: String
        @Guide(description: "One short sentence on why it is sensitive.")
        let reason: String
    }

    @Generable
    struct Output {
        @Guide(description: "Sensitive items the rules likely missed — only ones NOT in the already-detected list.")
        let additional: [Finding]
        @Guide(description: "Already-detected items that are NOT actually sensitive (false positives), each exactly as listed.")
        let falsePositives: [String]
    }

    let maxOCRChars: Int
    init(maxOCRChars: Int = 4_000) { self.maxOCRChars = maxOCRChars }

    func review(ocrText: String,
                alreadyDetected: [String]) async -> (additional: [RedactionFinding], falsePositives: [String]) {
        let prompt = RedactionPromptBuilder.prompt(ocrText: ocrText,
                                                   alreadyDetected: alreadyDetected,
                                                   maxOCRChars: maxOCRChars)
        do {
            let session = LanguageModelSession(instructions: RedactionPromptBuilder.instructions)
            let out = try await session.respond(to: prompt, generating: Output.self).content
            let findings = out.additional.map {
                RedactionFinding(text: $0.text, type: $0.type, reason: $0.reason)
            }
            return (findings, out.falsePositives)
        } catch {
            return ([], [])
        }
    }
}
#endif
