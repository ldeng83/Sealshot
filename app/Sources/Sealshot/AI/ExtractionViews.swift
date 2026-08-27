import Foundation

/// Derives the textual views shown in the Extract result window from the stored
/// `StructuredItems`. (Markdown is the record's stored `markdown`; the Table view
/// reuses the existing structured table rendering.)
enum ExtractionViews {

    /// All detected tables as CSV, blank-line separated. Empty when no tables.
    static func csv(_ items: StructuredItems) -> String {
        items.tables.map(TableExport.csv).joined(separator: "\n\n")
    }

    /// All detected tables as TSV, blank-line separated. Empty when no tables.
    static func tsv(_ items: StructuredItems) -> String {
        items.tables.map(TableExport.tsv).joined(separator: "\n\n")
    }

    /// The full structured items as pretty-printed JSON.
    static func json(_ items: StructuredItems) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
