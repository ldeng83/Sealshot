import Foundation

struct TagSuggestion: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case canonical, existing }
    let tag: String
    let kind: Kind
    let count: Int?
}

/// A live, in-memory index of every tag in use across the library, used to
/// steer manual tag entry toward existing tags (autocomplete). Derived from
/// `LibraryIndexDB`; holds no I/O state, so it is cheap to rebuild. `Sendable`
/// so it can cross the `LibraryIndexStore` actor boundary back to the main
/// actor (Task 4).
struct TagVocabulary: Sendable {

    /// Canonical tag -> usage count, sorted by count desc then tag asc.
    let entries: [(tag: String, count: Int)]

    init(entries: [(tag: String, count: Int)]) {
        self.entries = entries.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag
        }
    }

    /// Build from the SQLite-backed library index. Tags in the index are already
    /// stored canonical (they pass through `TagNormalizer` on write); we run them
    /// through `normalize` again defensively so the vocabulary is always canonical.
    static func build(from db: LibraryIndexDB) -> TagVocabulary {
        let raw = (try? db.allTags()) ?? []
        var counts: [String: Int] = [:]
        for entry in raw {
            guard let canonical = TagNormalizer.normalize([entry.tag]).first else { continue }
            counts[canonical, default: 0] += entry.count
        }
        let entries = counts.map { (tag: $0.key, count: $0.value) }
        return TagVocabulary(entries: entries)
    }

    /// Non-destructive suggestions for a partial input. Never mutates the input;
    /// offers the computed canonical (singular/synonym) plus existing tags.
    func suggestions(for partial: String, limit: Int) -> [TagSuggestion] {
        guard let typed = TagNormalizer.format([partial]).first, !typed.isEmpty else { return [] }
        var out: [TagSuggestion] = []
        var seen = Set<String>()
        func add(_ s: TagSuggestion) { if seen.insert(s.tag).inserted { out.append(s) } }

        if let canonical = TagNormalizer.normalize([partial]).first, canonical != typed {
            let count = entries.first(where: { $0.tag == canonical })?.count
            add(TagSuggestion(tag: canonical, kind: .canonical, count: count))
        }
        for e in entries where e.tag != typed && e.tag.hasPrefix(typed) {
            add(TagSuggestion(tag: e.tag, kind: .existing, count: e.count))
        }
        // Fuzzy typo matches: a candidate must SHARE THE FIRST CHARACTER (typos
        // rarely change the first letter) and lie within a length-scaled edit
        // distance — ≤1 for short inputs, ≤2 only once the input is long enough
        // that two edits still leave it recognizable. This keeps real typos
        // ("paymnt"→"payment") while rejecting unrelated short words
        // ("test"→"pet", which is distance 2 but a different word).
        let maxFuzzy = typed.count >= 6 ? 2 : 1
        for e in entries where e.tag != typed && !seen.contains(e.tag)
            && e.tag.first == typed.first
            && Self.editDistance(e.tag, typed) <= maxFuzzy {
            add(TagSuggestion(tag: e.tag, kind: .existing, count: e.count))
        }
        return Array(out.prefix(limit))
    }

    /// Standard Levenshtein edit distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}
