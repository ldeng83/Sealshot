import Foundation

/// Pure construction of the instructions + prompt for FM-assisted Smart
/// Redaction. No model dependency, so it's unit-testable on any OS.
enum RedactionPromptBuilder {
    static let instructions = """
    You find sensitive personal information in a screenshot's text that simple \
    pattern rules might miss — verification/confirmation codes, passport and \
    license numbers, account numbers, a person's name tied to sensitive \
    context, and similar. For each, return the EXACT substring as it appears, a \
    short type label (e.g. "Confirmation code", "Passport number"), and one \
    short sentence on why it's sensitive. Do NOT repeat anything already in the \
    already-detected list. Also review the already-detected items and list any \
    that are NOT actually sensitive (false positives), such as version numbers \
    or order IDs. Base everything only on the provided text.
    """

    static func prompt(ocrText: String, alreadyDetected: [String], maxOCRChars: Int) -> String {
        var parts = ["Screen text (OCR):\n\(MetadataPromptBuilder.ocrExcerpt(ocrText, maxChars: maxOCRChars))"]
        if !alreadyDetected.isEmpty {
            parts.append("Already detected (review for false positives):\n"
                         + alreadyDetected.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
