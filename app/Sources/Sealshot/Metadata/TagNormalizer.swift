import Foundation
import NaturalLanguage

/// Cleans raw tag candidates. Two entry points:
/// - `format`  — formatting only: lowercase-kebab, strip, dedup, cap. Keeps the
///               caller's words intact (no singular/synonym). Used by manual entry.
/// - `normalize` — `format` + plural→singular (shape-guarded) + synonym mapping.
///               Used by auto-tagging and as the "suggested canonical" source.
enum TagNormalizer {

    static let maxTags = 8

    private static let synonyms: [String: String] = [
        "js": "javascript", "ts": "typescript",
        "authn": "authentication", "authz": "authorization",
        "mac-os": "macos", "sso-login": "sso",
        "bug-report": "bug", "defect": "bug"
    ]

    private static let protectedFromSingularization: Set<String> =
        Set(ScreenshotCategory.allCases.map(\.rawValue))

    /// Formatting only — no semantic rewrite.
    static func format(_ raw: [String]) -> [String] {
        dedupAndCap(raw.compactMap { formatToken($0) })
    }

    /// Formatting + singularization + synonyms.
    static func normalize(_ raw: [String]) -> [String] {
        dedupAndCap(raw.compactMap { canonicalToken($0) })
    }

    // MARK: - token pipeline

    /// lowercase → kebab → strip unsafe → collapse hyphens. nil if empty.
    private static func formatToken(_ tag: String) -> String? {
        let kebab = tag
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let cleaned = String(kebab.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        })
        let collapsed = cleaned
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// formatToken + per-subtoken singularization + synonym mapping.
    private static func canonicalToken(_ tag: String) -> String? {
        guard let collapsed = formatToken(tag) else { return nil }
        let singular = collapsed
            .split(separator: "-")
            .map { singularizeToken(String($0)) }
            .joined(separator: "-")
        return synonyms[singular] ?? singular
    }

    private static func dedupAndCap(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in tags where seen.insert(t).inserted {
            out.append(t)
            if out.count == maxTags { break }
        }
        return out
    }

    /// Collapse a plural noun to singular via NLTagger lemma, accepting ONLY
    /// plural→singular shapes so verbs/adjectives, Latin -us words, codes and
    /// category names are left untouched.
    private static func singularizeToken(_ token: String) -> String {
        guard token.count >= 4,
              token.allSatisfy({ $0.isLetter }),
              !protectedFromSingularization.contains(token) else { return token }
        let tagger = NLTagger(tagSchemes: [.lemma])
        let contextual = "the \(token)"
        tagger.string = contextual
        let idx = contextual.index(contextual.startIndex, offsetBy: 4)
        guard let lemma = tagger.tag(at: idx, unit: .word, scheme: .lemma).0?
                .rawValue.lowercased(),
              !lemma.isEmpty, lemma != token else { return token }
        if token == lemma + "s" || token == lemma + "es" { return lemma }
        if token.hasSuffix("ies") && lemma.hasSuffix("y") &&
            token.dropLast(3) == lemma.dropLast(1) { return lemma }
        return token
    }
}
