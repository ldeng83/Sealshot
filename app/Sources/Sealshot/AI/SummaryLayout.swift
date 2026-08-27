import AppKit

/// Parses a stored summary into an overview line + bullet fragments and composes
/// the whole thing into ONE attributed string for the Info panel: keyword and
/// Markdown-bold emphasis rendered as semibold (no colour change), line-spaced,
/// with hanging-indented bullets. Backward compatible — a summary with no bullet
/// lines renders as a single block.
enum SummaryLayout {

    private static let bulletPrefixes = ["- ", "• ", "* ", "– "]

    /// Split into a leading overview (joined pre-bullet lines) and bullet
    /// fragments (lines starting with a bullet marker). Blank lines are ignored.
    static func parse(_ summary: String) -> (overview: String, bullets: [String]) {
        let lines = summary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var overviewLines: [String] = []
        var bullets: [String] = []
        for line in lines {
            if let b = bulletText(line) {
                bullets.append(b)
            } else if bullets.isEmpty {
                overviewLines.append(line)
            } else {
                bullets.append(line)
            }
        }
        return (overviewLines.joined(separator: " "), bullets)
    }

    private static func bulletText(_ line: String) -> String? {
        for p in bulletPrefixes where line.hasPrefix(p) {
            return String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Strip Markdown bold markers (`**`) and report the emphasised ranges in the
    /// cleaned string. Unbalanced markers are left untouched.
    static func stripMarkdownBold(_ text: String) -> (text: String, boldRanges: [NSRange]) {
        guard text.contains("**") else { return (text, []) }
        var out = ""
        var ranges: [NSRange] = []
        var openAt: Int?
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if text[i] == "*", next < text.endIndex, text[next] == "*" {
                let here = (out as NSString).length
                if let start = openAt {
                    if here > start { ranges.append(NSRange(location: start, length: here - start)) }
                    openAt = nil
                } else {
                    openAt = here
                }
                i = text.index(i, offsetBy: 2)
            } else {
                out.append(text[i])
                i = next
            }
        }
        if openAt != nil { return (text, []) }   // unbalanced → leave as-is
        return (out, ranges)
    }

    /// Compose the full summary into one attributed string: overview paragraph +
    /// bullet paragraphs (hanging indent), keyword + Markdown-bold emphasis as
    /// semibold in `bodyColor` (no colour change), `lineHeightMultiple` spacing.
    static func attributedSummary(_ summary: String, tags: [String], font: NSFont,
                                  bodyColor: NSColor, bulletColor: NSColor,
                                  lineHeightMultiple: CGFloat) -> NSAttributedString {
        let parsed = parse(summary)
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)

        func body(_ text: String) -> NSMutableAttributedString {
            let (plain, mdBold) = stripMarkdownBold(text)
            let kw = SummaryKeywordHighlighter.keywordRanges(in: plain, tags: tags)
            let a = NSMutableAttributedString(
                string: plain, attributes: [.font: font, .foregroundColor: bodyColor])
            let len = (plain as NSString).length
            for r in (mdBold + kw) where r.location != NSNotFound && NSMaxRange(r) <= len {
                a.addAttribute(.font, value: bold, range: r)   // emphasis = bold only
            }
            return a
        }

        func paragraphStyle(bullet: Bool, spacingAfter: CGFloat) -> NSParagraphStyle {
            let ps = NSMutableParagraphStyle()
            ps.lineHeightMultiple = lineHeightMultiple
            ps.lineBreakMode = .byWordWrapping
            ps.paragraphSpacing = spacingAfter
            if bullet {
                let indent: CGFloat = 14
                ps.firstLineHeadIndent = 0
                ps.headIndent = indent
                ps.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            return ps
        }

        var segments: [(NSMutableAttributedString, NSParagraphStyle)] = []
        if !parsed.overview.isEmpty {
            segments.append((body(parsed.overview),
                             paragraphStyle(bullet: false, spacingAfter: parsed.bullets.isEmpty ? 0 : 5)))
        }
        for b in parsed.bullets {
            let line = NSMutableAttributedString(
                string: "•\t", attributes: [.font: font, .foregroundColor: bulletColor])
            line.append(body(b))
            segments.append((line, paragraphStyle(bullet: true, spacingAfter: 3)))
        }

        let result = NSMutableAttributedString()
        for (idx, seg) in segments.enumerated() {
            let m = seg.0
            if idx < segments.count - 1 {
                m.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: bodyColor]))
            }
            m.addAttribute(.paragraphStyle, value: seg.1, range: NSRange(location: 0, length: m.length))
            result.append(m)
        }
        return result
    }
}
