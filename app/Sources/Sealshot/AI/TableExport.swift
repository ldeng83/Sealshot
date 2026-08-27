import Foundation

/// Pure CSV/TSV serialization of a StructuredTable. Foundation only — no AppKit.
enum TableExport {

    /// RFC 4180 CSV. A field is quoted iff it contains a comma, double-quote,
    /// CR, or LF; inner double-quotes are doubled. Rows joined with CRLF.
    static func csv(_ table: StructuredTable) -> String {
        normalizedRows(table)
            .map { row in row.map(csvField).joined(separator: ",") }
            .joined(separator: "\r\n")
    }

    /// Tab-separated. Each cell has tab/CR/LF replaced with a single space
    /// (TSV has no escape mechanism). Rows joined with LF.
    static func tsv(_ table: StructuredTable) -> String {
        normalizedRows(table)
            .map { row in row.map(tsvCell).joined(separator: "\t") }
            .joined(separator: "\n")
    }

    // MARK: - helpers

    /// Headers row first, then data rows, each normalized to a common column
    /// count: width = header count, or the widest row when headers are empty.
    private static func normalizedRows(_ table: StructuredTable) -> [[String]] {
        let all = [table.headers] + table.rows
        let width = table.headers.isEmpty ? (all.map(\.count).max() ?? 0) : table.headers.count
        return all.map { row in
            if row.count < width { return row + Array(repeating: "", count: width - row.count) }
            if row.count > width { return Array(row.prefix(width)) }
            return row
        }
    }

    private static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func tsvCell(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ")
         .replacingOccurrences(of: "\r\n", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }
}
