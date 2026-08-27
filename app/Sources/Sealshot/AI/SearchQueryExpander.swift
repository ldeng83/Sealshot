import Foundation

/// Pure helpers for AI-assisted Library search. The model expands a natural
/// query into related keywords; these build the FTS5 query and the prompt. No
/// model dependency — unit-testable on any OS.
enum SearchQueryExpander {
    /// Build an FTS5 OR prefix-query from terms, e.g. `"auth"* OR "401"*`.
    /// Sanitizes (escapes quotes), trims, and drops empty / case-insensitive
    /// duplicate terms. Returns nil when no usable term remains.
    static func ftsOrQuery(terms: [String]) -> String? {
        var seen = Set<String>()
        var parts: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
            parts.append("\"\(escaped)\"*")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " OR ")
    }
}

/// Instructions + prompt for the search-query expansion model call.
enum SearchQueryPromptBuilder {
    static let instructions = """
    You expand a search query for a personal screenshot library into a short \
    list of keywords to match against text inside the screenshots. Include the \
    original words, close synonyms, and obvious related terms (e.g. error codes \
    for an error query). Prefer lowercase single words; no explanations.
    """

    static func prompt(query: String) -> String {
        "Search query: \(query)"
    }
}
