/// Ordered stages of the Markdown extraction pipeline, for the staged progress
/// overlay. Coarse per-tier fractions (like the redaction staged bar).
enum ExtractionStage: Int, CaseIterable {
    case reading, tables, detecting, entities, composing

    // User-facing step copy: a generic progression (read → analyze → detect →
    // identify → organize) that doesn't leak pipeline internals like table
    // detection or Markdown composition.
    var label: String {
        switch self {
        case .reading:   return "Reading text…"
        case .tables:    return "Analyzing structure…"
        case .detecting: return "Detecting data…"
        case .entities:  return "Identifying key information…"
        case .composing: return "Organizing results…"
        }
    }

    /// Fraction at the START of this stage, within [0, 1).
    var fraction: Double { Double(rawValue) / Double(ExtractionStage.allCases.count) }
}
