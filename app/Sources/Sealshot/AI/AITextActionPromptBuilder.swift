import Foundation

/// Pure instructions + prompt for the on-demand text actions (Summarize /
/// Extract). No model dependency, so it's unit-testable on any OS.
enum AITextActionPromptBuilder {
    static let summaryInstructions = """
    Summarize what this screenshot shows in 1–3 short, complete sentences, \
    based only on its text. Keep the whole summary under about 45 words, and \
    never end mid-thought — every sentence must be finished. Be specific and \
    concise; don't speculate beyond what's present.
    """

    /// Compact, scannable summary for the Info panel: one short overview line
    /// then a few bullet fragments. Tight on length; plain text only.
    static let infoSummaryInstructions = """
    Summarize this screenshot for a compact info panel, based only on its text. \
    Start with a single plain overview sentence (do NOT label it "Overview" or add \
    any heading), then up to three bullet points — each on its own line starting \
    with "- " — of the most important facts, each a short fragment. Keep the whole \
    summary under about 40 words. Use plain text only: no Markdown, no asterisks, \
    no bold, and no section labels like "Important Facts". Be specific and do not \
    add filler like "This screenshot shows" or speculate beyond what's present.
    """

    /// ONE sentence describing a single Live Capture window, for that window's
    /// bullet in a scene summary. Neither existing summary instruction fits: the
    /// Summarize one asks for "1–3 short, complete sentences" (~45 words), and
    /// the Info-panel one emits its own overview line plus up to three bullets —
    /// nesting a bullet list inside a bullet. A scene bullet is also clamped to
    /// 120 characters, so the sentence has to be short by instruction rather
    /// than by truncation. The app name and window title are prepended from the
    /// manifest, so the model is told not to repeat them.
    static let windowSummaryInstructions = """
    Describe what this window shows in ONE short, complete sentence, based only \
    on its text. Keep it under about 16 words. Do not use bullet points, lists, \
    line breaks, headings, or Markdown, and never write more than one sentence. \
    Do not name the application or repeat the window's title. Be specific and \
    don't speculate beyond what's present.
    """

    static let extractInstructions = """
    Extract the key structured information from this screenshot's text — tables, \
    lists, key/value fields, code, or contact details — as clean Markdown. \
    Include only what is present; add no commentary.
    """

    /// Compose ONE clean Markdown document from the deterministic structured
    /// extraction plus the raw OCR text. `hasTable` reflects whether the structured
    /// extraction actually found a table — when it didn't, the model is told NOT to
    /// invent one, since forcing non-tabular text into a table garbles the data.
    static func markdownComposeInstructions(hasTable: Bool) -> String {
        let tableRule = hasTable
            ? "Keep any Markdown tables from the structured extraction VERBATIM."
            : "Do NOT use Markdown tables — the source has no tabular data; present "
              + "everything as headings, lists, and paragraphs."
        return """
        You are given a screenshot's raw text and a structured extraction of it. \
        Produce ONE clean, well-organized Markdown document of what the screenshot \
        contains. \(tableRule) Use headings and lists where helpful. Include only \
        what is present; add no commentary.
        """
    }

    static func prompt(ocrText: String, maxOCRChars: Int) -> String {
        "Screen text (OCR):\n\(MetadataPromptBuilder.ocrExcerpt(ocrText, maxChars: maxOCRChars))"
    }
}
