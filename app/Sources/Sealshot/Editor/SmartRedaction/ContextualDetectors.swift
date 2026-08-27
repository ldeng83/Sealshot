import Foundation
import NaturalLanguage

/// Semantic detectors that complement the regex rules in `SensitiveTextRules`:
/// content with no fixed format (person/organization/place names, postal
/// addresses) or that is sensitive only next to a label (DOB, salary,
/// account…). Everything runs on-device via `NLTagger` and `NSDataDetector`
/// — no permission, no entitlement, no network — and produces the same
/// `SensitiveMatch` (character-offset ranges) the combiner expects.
enum ContextualDetectors {

    /// All semantic matches (anchored + NER) — the engine-off path. Behavior
    /// unchanged from before the split.
    static func matches(in text: String) -> [SensitiveMatch] {
        anchoredMatches(in: text) + namedEntityMatches(in: text)
    }

    /// High-precision, label/format-anchored matches that run in EVERY scan
    /// (including alongside the GLiNER2 engine): labeled values + postal
    /// addresses. No NLTagger NER (that's `namedEntityMatches`).
    static func anchoredMatches(in text: String) -> [SensitiveMatch] {
        labeledFieldMatches(in: text) + addressMatches(in: text)
    }

    // MARK: - Labeled fields (label : value — redact only the value)

    /// Personal-data labels whose adjacent value should be redacted. A
    /// separator (`:`/`=`/`-`) is required, so a bare label word in prose
    /// ("the patient was discharged") never matches. Group 2 is the value.
    /// Label alternatives are sourced from `SensitiveLabels.valueLabelAlternation`.
    /// `\)?` before the separator: ops consoles wrap the label in a
    /// parenthetical qualifier — "org_context (internal ticket): PRIV-2939".
    /// The value runs to end of line but stops at a quote: a quoted value
    /// belongs to the structured rule below, which captures it exactly.
    /// Running past it here would swallow trailing syntax and, being longer,
    /// out-rank the precise rules (openAIKey, email) that name the same value.
    private static let labeledValueRegex = try! NSRegularExpression(pattern:
        #"(?i)(?<![A-Za-z0-9])("# + SensitiveLabels.valueLabelAlternation
        + #")\s*\)?(?:\s*[:=]\s*|\s+-\s+)([^\s"'`][^"'`\n]*?)\s*$"#)

    /// The same labels in a STRUCTURED document — JSON, YAML, plists, `.env`
    /// dumps — where the key is quoted and the value is a quoted literal:
    /// `"password": "hunter2",`.
    ///
    /// This needs its own rule rather than loosening the one above. The
    /// closing quote after the key sits between the label and the separator,
    /// so every label rule was dead on such a screenshot — and a developer's
    /// most sensitive screenshots are exactly these. (What still got boxed
    /// there was caught incidentally by token shape or entropy, which is why
    /// coverage looked arbitrary rather than absent.) Matching the closing
    /// quote of the VALUE too keeps the capture exact: to the end of line, as
    /// the prose rule does, it would swallow trailing syntax and out-rank the
    /// precise rules (openAIKey, email) that already name the same value.
    ///
    /// `(?<![A-Za-z0-9])` rather than `\b` so a label can begin after `_` —
    /// `vpn_password`, `github_token` — which `\b` cannot see inside a
    /// snake_case key.
    private static let quotedLabeledValueRegex = try! NSRegularExpression(pattern:
        #"(?i)(?<![A-Za-z0-9])("# + SensitiveLabels.valueLabelAlternation
        + #")["'`\]>]*\s*\)?\s*[:=]>?\s*["'`]([^"'`\n]{1,200})["'`]"#)

    /// Money labels whose currency/number value should be redacted. Requires a
    /// currency symbol or a 4+ digit amount so "pay 5" doesn't match. Group 2.
    private static let moneyLabelRegex = try! NSRegularExpression(pattern:
        #"(?i)\b(salary|compensation|comp|wage|income|pay)\b\s*[:=\-]?\s*"#
        + #"([$€£]\s?[\d,]+(?:\.\d{2})?|[\d,]{4,}(?:\.\d{2})?)"#)

    private static func labeledFieldMatches(in text: String) -> [SensitiveMatch] {
        var out: [SensitiveMatch] = []
        for regex in [labeledValueRegex, quotedLabeledValueRegex, moneyLabelRegex] {
            SensitiveTextRules.enumerate(regex, in: text, group: 2) { value, range in
                out.append(SensitiveMatch(category: .labeledField, text: value, range: range))
            }
        }
        return out
    }

    // MARK: - Postal addresses (NSDataDetector)

    private static let addressDetector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue)

    private static func addressMatches(in text: String) -> [SensitiveMatch] {
        guard let detector = addressDetector else { return [] }
        var out: [SensitiveMatch] = []
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        detector.enumerateMatches(in: text, options: [], range: ns) { result, _, _ in
            guard let result, result.resultType == .address,
                  let r = Range(result.range, in: text) else { return }
            out.append(SensitiveMatch(category: .postalAddress,
                                      text: String(text[r]), range: charRange(r, in: text)))
        }
        return out
    }

    // MARK: - Named entities (NLTagger)

    static func namedEntityMatches(in text: String) -> [SensitiveMatch] {
        // NER on a word or two is mostly noise; skip very short lines.
        guard text.count >= 3 else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var out: [SensitiveMatch] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, tokenRange in
            if let tag, let category = category(for: tag) {
                out.append(SensitiveMatch(category: category,
                                          text: String(text[tokenRange]),
                                          range: charRange(tokenRange, in: text)))
            }
            return true
        }
        return out
    }

    private static func category(for tag: NLTag) -> SensitiveCategory? {
        if tag == .personalName { return .personName }
        if tag == .organizationName { return .organizationName }
        if tag == .placeName { return .placeName }
        return nil
    }

    // MARK: - Helpers

    /// Character-offset range (indexes into the line's characters), matching
    /// `SensitiveMatch.range` semantics used by the box mapping.
    private static func charRange(_ r: Range<String.Index>, in text: String) -> Range<Int> {
        let lower = text.distance(from: text.startIndex, to: r.lowerBound)
        let length = text.distance(from: r.lowerBound, to: r.upperBound)
        return lower..<(lower + length)
    }
}
