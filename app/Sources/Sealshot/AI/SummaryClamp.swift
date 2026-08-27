import Foundation

/// Hard bound on a generated Info-panel summary, applied to the model's output
/// before it's stored. The on-device model sometimes ignores the length
/// instruction (especially on dense screenshots) and returns a long list; this
/// clamps it deterministically so a runaway summary can never persist — while
/// keeping every kept sentence COMPLETE. The original guillotine (`prefix(160)`
/// on the first sentence only) shipped summaries cut mid-word ("along with
/// comments abo") and discarded any 2nd/3rd sentence entirely.
enum SummaryClamp {
    static let maxOverviewChars = 240
    static let maxBulletChars = 80
    static let maxBullets = 3
    static let maxTotalChars = 360

    /// Per-window bullet budget for a Live Capture scene. Wider than the
    /// ordinary bullet because a scene bullet carries a label ("App — Window
    /// Title: ") before the sentence.
    static let sceneMaxBulletChars = 120

    /// Characters `clamp` adds around a bullet when it COMPOSES the output but
    /// which the caller never passes in: the `"- "` prefix and the newline that
    /// joins the bullet to the part before it.
    static let bulletOverheadChars = 3      // "- " + "\n"

    /// The `maxTotalChars` a caller must pass for `count` bullets of up to
    /// `perBullet` characters each to ALL survive. `maxTotalChars` bounds the
    /// composed string, so a caller that budgets only for the text it hands in
    /// is short by the prefix and separator `clamp` adds — and the total bound
    /// then deletes whole trailing bullets. For a scene that silently drops a
    /// captured window, so the arithmetic lives here rather than at the call
    /// site.
    static func totalBudget(bullets count: Int, perBullet: Int) -> Int {
        max(1, count) * (perBullet + bulletOverheadChars)
    }

    /// Keep as many complete overview sentences as fit + up to `maxBullets`
    /// short bullets, each and the whole thing length-capped at word
    /// boundaries. Returns nil when nothing meaningful remains.
    ///
    /// The defaults are the bound for ordinary captures. Live Capture passes
    /// its own: a scene lists one bullet per window, and the window count is
    /// finite and known before the model runs, so its bound is derived from
    /// the data rather than being a second invented constant.
    static func clamp(_ raw: String,
                      maxBullets: Int = Self.maxBullets,
                      maxBulletChars: Int = Self.maxBulletChars,
                      maxTotalChars: Int = Self.maxTotalChars) -> String? {
        let (overviewRaw, bulletsRaw) = SummaryLayout.parse(raw)
        let overview = packSentences(overviewRaw, budget: maxOverviewChars)
        let bullets = bulletsRaw.prefix(maxBullets)
            .map { $0.wordClamped(maxBulletChars) }
            .filter { !$0.isEmpty }

        var parts: [String] = []
        if !overview.isEmpty { parts.append(overview) }
        parts.append(contentsOf: bullets.map { "- \($0)" })

        // Total bound: drop whole trailing bullets before ever cutting text.
        while parts.count > 1,
              parts.joined(separator: "\n").count > maxTotalChars {
            parts.removeLast()
        }
        let composed = parts.joined(separator: "\n")
            .wordClamped(maxTotalChars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return composed.isEmpty ? nil : composed
    }

    /// As many COMPLETE sentences as fit `budget`, in order. When even the
    /// first sentence exceeds it, that sentence is cut at a word boundary
    /// with an ellipsis — never mid-word.
    static func packSentences(_ text: String, budget: Int) -> String {
        let all = sentences(text)
        var kept: [String] = []
        var length = 0
        for s in all {
            let added = s.count + (kept.isEmpty ? 0 : 1)   // +1 joining space
            guard length + added <= budget else { break }
            kept.append(s)
            length += added
        }
        if kept.isEmpty, let first = all.first {
            return first.wordClamped(budget)
        }
        return kept.joined(separator: " ")
    }

    /// Split into sentences on . ! ? — the terminator may be followed by
    /// closing quotes/brackets, and counts only when whitespace (or the end)
    /// follows, so "3.5" or a mid-token dot never splits. An embedded
    /// quoted period ("Gaming." mid-sentence) still splits, which is safe:
    /// the pieces are PACKED back together, never discarded.
    static func sentences(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", "\u{00BB}"]
        var out: [String] = []
        var current = ""
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            current.append(c)
            i = t.index(after: i)
            guard c == "." || c == "!" || c == "?" else { continue }
            while i < t.endIndex, closers.contains(t[i]) {
                current.append(t[i])
                i = t.index(after: i)
            }
            if i == t.endIndex || t[i].isWhitespace {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                current = ""
                while i < t.endIndex, t[i].isWhitespace { i = t.index(after: i) }
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }
}

extension String {
    /// Truncate to at most `max` characters at a WORD boundary, appending an
    /// ellipsis (dangling punctuation trimmed first). Falls back to a hard cut
    /// only when the text has no spaces at all. Internal for SummaryClamp tests.
    func wordClamped(_ max: Int) -> String {
        guard count > max else { return self }
        let head = String(prefix(max - 1))
        let base: Substring
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            base = head[..<lastSpace]
        } else {
            base = head[...]
        }
        var trimmed = base.trimmingCharacters(in: .whitespaces)
        while let last = trimmed.last, ",;:—-–".contains(last) {
            trimmed.removeLast()
        }
        return trimmed + "…"
    }
}
