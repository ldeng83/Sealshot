import AppKit
import NaturalLanguage

/// Display-time keyword emphasis for the Info-panel summary: bolds the most
/// relevant terms in the accent colour. Keywords are the union of the capture's
/// own tags (appearing in the summary), confident named entities (person / place
/// / organization), and multi-word noun phrases ("login error"), de-overlapped and
/// capped so it never over-lights. On-device, deterministic, no regeneration.
enum SummaryKeywordHighlighter {

    private struct Candidate {
        let range: NSRange
        /// 0 = tag match, 1 = named entity, 2 = noun phrase. Lower wins on overlap.
        let priority: Int
    }

    /// Keyword ranges in `text`, highest-value first, non-overlapping, ≤ `maxKeywords`.
    /// `tags` are the capture's metadata tags (highlighted where they appear).
    static func keywordRanges(in text: String, tags: [String] = [],
                              maxKeywords: Int = 5, minConfidence: Double = 0.5) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        var candidates: [Candidate] = []

        // (0) Tag matches — the capture's own tags appearing in the summary.
        for tag in tags {
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3 else { continue }
            var from = text.startIndex
            while let r = text.range(of: t, options: [.caseInsensitive],
                                     range: from..<text.endIndex) {
                candidates.append(Candidate(range: NSRange(r, in: text), priority: 0))
                from = r.upperBound
            }
        }

        // (1) Named entities — confident person / place / organization.
        let entities: Set<NLTag> = [.personalName, .placeName, .organizationName]
        let nameTagger = NLTagger(tagSchemes: [.nameType])
        nameTagger.string = text
        nameTagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag, entities.contains(tag) else { return true }
            let hyp = nameTagger.tagHypotheses(
                at: range.lowerBound, unit: .word, scheme: .nameType, maximumCount: 3).0
            if (hyp[tag.rawValue] ?? 0) >= minConfidence {
                candidates.append(Candidate(range: NSRange(range, in: text), priority: 1))
            }
            return true
        }

        // (2) Multi-word noun phrases — runs of ≥ 2 consecutive nouns ("login
        // error", "invoice total"). Single trivial nouns ("page") are skipped.
        let lexTagger = NLTagger(tagSchemes: [.lexicalClass])
        lexTagger.string = text
        var phraseStart: String.Index?
        var phraseEnd: String.Index?
        var nounCount = 0
        func flushPhrase() {
            if let s = phraseStart, let e = phraseEnd, nounCount >= 2 {
                candidates.append(Candidate(range: NSRange(s..<e, in: text), priority: 2))
            }
            phraseStart = nil; phraseEnd = nil; nounCount = 0
        }
        lexTagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
            options: [.omitWhitespace]
        ) { tag, range in
            if tag == .noun {
                if phraseStart == nil { phraseStart = range.lowerBound }
                phraseEnd = range.upperBound
                nounCount += 1
            } else {
                flushPhrase()
            }
            return true
        }
        flushPhrase()

        // Greedy non-overlapping pick: priority, then longest, then earliest.
        let ordered = candidates.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.range.location < $1.range.location
        }
        var chosen: [NSRange] = []
        for c in ordered {
            guard chosen.count < maxKeywords else { break }
            if chosen.allSatisfy({ NSIntersectionRange($0, c.range).length == 0 }) {
                chosen.append(c.range)
            }
        }
        return chosen.sorted { $0.location < $1.location }
    }
}
