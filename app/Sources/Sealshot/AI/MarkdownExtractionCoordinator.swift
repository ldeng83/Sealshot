import CoreGraphics

/// Builds one Markdown document from the deterministic structured extraction,
/// optionally polished by the Foundation Model. The FM is never required: when it
/// is unavailable (or returns nothing) the deterministic baseline is the result,
/// so Extract always works and always outputs Markdown.
@MainActor
struct MarkdownExtractionCoordinator {

    /// (structured markdown, ocr text) → composed markdown, or nil to fall back.
    /// Injected for tests; the default uses the on-device FM when available.
    /// The third argument (`hasTable`) tells the composer whether a table was
    /// actually found, so it never forces non-tabular text into one.
    let composeFM: ((String, String, Bool) async -> String?)?

    init(composeFM: ((String, String, Bool) async -> String?)? = MarkdownExtractionCoordinator.defaultCompose) {
        self.composeFM = composeFM
    }

    /// Compose the Markdown from already-extracted items + OCR text.
    func markdown(items: StructuredItems, ocrText: String) async -> String {
        let groups = StructuredExtractionResult.groups(from: items)
        var baseline = StructuredExtractionResult.copyAllText(groups)
        let trimmedOCR = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOCR.isEmpty {
            baseline += (baseline.isEmpty ? "" : "\n\n") + "## Text\n" + trimmedOCR
        }
        let hasTable = !items.tables.isEmpty
        if let composeFM, let polished = await composeFM(baseline, ocrText, hasTable), !polished.isEmpty {
            return polished
        }
        return baseline
    }

    private static func defaultCompose(_ structured: String, _ ocrText: String, _ hasTable: Bool) async -> String? {
        guard AIAvailability.isFoundationModelAvailable, AIFeaturePreference().enabled else { return nil }
        if #available(macOS 26, *) {
            return await FoundationTextActions().composeMarkdown(
                structured: structured, ocrText: ocrText, hasTable: hasTable)
        }
        return nil
    }
}
