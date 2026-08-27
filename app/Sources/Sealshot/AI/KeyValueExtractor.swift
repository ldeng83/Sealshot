import CoreGraphics

/// Pure geometric key-value extraction over OCR tokens. CoreGraphics only.
enum KeyValueExtractor {

    /// Extract key-value fields using two patterns: inline-colon ("Key: value"
    /// on one line) and two-column (label column / value column, enabled only
    /// when the layout has exactly two columns). Returns deduped fields in
    /// reading order.
    static func extract(_ tokens: [LayoutToken],
                        tolerance: CGFloat,
                        columnSeparation: CGFloat) -> [StructuredField] {
        let rows = TableReconstructor.clusterRows(tokens, tolerance: tolerance)
        let cuts = TableReconstructor.columnBoundaries(tokens, minSeparation: columnSeparation)
        let twoColumn = cuts.count == 1

        var fields: [StructuredField] = []
        for row in rows {
            let joined = row.map(\.text).joined(separator: " ")

            // Inline-colon: split on the FIRST colon.
            if let colon = joined.firstIndex(of: ":") {
                let key   = String(joined[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(joined[joined.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if isField(key: key, value: value) {
                    fields.append(StructuredField(label: key, value: value))
                    continue
                }
            }

            // Two-column: only when the layout has exactly two columns.
            if twoColumn {
                let parts = TableReconstructor.assignColumns(row, boundaries: cuts)
                if parts.count == 2 {
                    let key   = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    if isField(key: key, value: value) {
                        fields.append(StructuredField(label: key, value: value))
                    }
                }
            }
        }

        // Order-preserving dedup (StructuredField is Equatable).
        var result: [StructuredField] = []
        for f in fields where !result.contains(f) { result.append(f) }
        return result
    }

    /// Prose-rejection heuristics.
    private static func isField(key: String, value: String) -> Bool {
        guard !key.isEmpty, !value.isEmpty else { return false }
        guard key.contains(where: { $0.isLetter }) else { return false }
        guard key.count <= 32 else { return false }
        guard key.split(whereSeparator: { $0.isWhitespace }).count <= 4 else { return false }
        let lower = key.lowercased()
        guard lower != "http", lower != "https" else { return false }
        guard value.split(whereSeparator: { $0.isWhitespace }).count <= 12 else { return false }
        return true
    }
}
