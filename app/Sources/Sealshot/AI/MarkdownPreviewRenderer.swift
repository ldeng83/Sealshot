import AppKit

/// Renders a Markdown string to an `NSAttributedString` for a live preview pane —
/// a lightweight, on-device, line-based renderer covering what Extract produces:
/// ATX headings, bullet/numbered lists, blockquotes, fenced code, GFM tables, and
/// inline emphasis (`**bold**`, `*italic*`, `` `code` ``). No web view, no deps.
enum MarkdownPreviewRenderer {

    static func render(_ markdown: String,
                       baseFont: NSFont = .systemFont(ofSize: 13),
                       textColor: NSColor = .labelColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var inCodeBlock = false
        var codeBuffer: [String] = []
        var tableBuffer: [String] = []

        func flushCode() {
            guard !codeBuffer.isEmpty else { return }
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 8
            out.append(NSAttributedString(string: codeBuffer.joined(separator: "\n") + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
                .foregroundColor: textColor,
                .paragraphStyle: para,
            ]))
            codeBuffer.removeAll()
        }

        func flushTable() {
            defer { tableBuffer.removeAll() }
            let rows = tableBuffer.map(cells(in:)).filter { !isSeparatorRow($0) }
            guard !rows.isEmpty else { return }
            let cols = rows.map(\.count).max() ?? 0
            var widths = [Int](repeating: 0, count: cols)
            for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
            let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
            let monoBold = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = 6
            para.lineBreakMode = .byClipping
            func pad(_ s: String, _ w: Int) -> String { s.padding(toLength: max(w, s.count), withPad: " ", startingAt: 0) }
            for (ri, r) in rows.enumerated() {
                let line = (0..<cols).map { pad($0 < r.count ? r[$0] : "", widths[$0]) }.joined(separator: "  │  ")
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: ri == 0 ? monoBold : mono, .foregroundColor: textColor, .paragraphStyle: para]))
                if ri == 0 {
                    let sep = (0..<cols).map { String(repeating: "─", count: widths[$0]) }.joined(separator: "──┼──")
                    out.append(NSAttributedString(string: sep + "\n", attributes: [
                        .font: mono, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para]))
                }
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
        }

        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if !tableBuffer.isEmpty { flushTable() }
                if inCodeBlock { flushCode() }
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { codeBuffer.append(raw); continue }

            // GFM table rows (our generated tables always have leading & trailing |).
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                tableBuffer.append(trimmed)
                continue
            }
            if !tableBuffer.isEmpty { flushTable() }

            if trimmed.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
                continue
            }

            if let (level, rest) = heading(trimmed) {
                let sizes: [CGFloat] = [23, 19, 16, 14, 13, 13]
                let size = sizes[min(level - 1, sizes.count - 1)]
                let para = NSMutableParagraphStyle()
                para.paragraphSpacingBefore = 10
                para.paragraphSpacing = 4
                append(inline(rest, font: .boldSystemFont(ofSize: size), color: textColor), para: para)
                continue
            }

            if let (marker, rest) = listItem(trimmed) {
                let para = NSMutableParagraphStyle()
                para.headIndent = 20
                para.paragraphSpacing = 2
                let item = NSMutableAttributedString(string: marker, attributes: [.font: baseFont, .foregroundColor: textColor])
                item.append(inline(rest, font: baseFont, color: textColor))
                append(item, para: para)
                continue
            }

            if trimmed.hasPrefix("> ") {
                let para = NSMutableParagraphStyle()
                para.headIndent = 14; para.firstLineHeadIndent = 14; para.paragraphSpacing = 4
                append(inline(String(trimmed.dropFirst(2)), font: baseFont, color: .secondaryLabelColor), para: para)
                continue
            }

            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 5
            append(inline(trimmed, font: baseFont, color: textColor), para: para)
        }
        if inCodeBlock { flushCode() }
        if !tableBuffer.isEmpty { flushTable() }
        return out

        func append(_ s: NSAttributedString, para: NSParagraphStyle) {
            let m = NSMutableAttributedString(attributedString: s)
            m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
            m.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            out.append(m)
        }
    }

    /// Plain text (Markdown syntax stripped) — the rendered string with bullets
    /// and table layout but no `#`/`*`/`|` markup.
    static func plainText(_ markdown: String) -> String { render(markdown).string }

    private static func cells(in row: String) -> [String] {
        var c = row.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if c.first == "" { c.removeFirst() }
        if c.last == "" { c.removeLast() }
        return c
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { c in
            !c.isEmpty && c.contains("-") && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func heading(_ s: String) -> (Int, String)? {
        var level = 0
        for ch in s { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = s.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()))
    }

    private static func listItem(_ s: String) -> (String, String)? {
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
            return ("•\t", String(s.dropFirst(2)))
        }
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let after = s.dropFirst(digits.count)
            if after.hasPrefix(". ") { return ("\(digits).\t", String(after.dropFirst(2))) }
        }
        return nil
    }

    /// Inline emphasis via `AttributedString(markdown:)` (inline-only), re-based
    /// onto `font`/`color` so bold/italic/code keep this run's size.
    private static func inline(_ s: String, font: NSFont, color: NSColor) -> NSAttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard let attributed = try? AttributedString(markdown: s, options: opts) else {
            return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.font, value: font, range: full)
        ns.addAttribute(.foregroundColor, value: color, range: full)
        ns.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            let intent: InlinePresentationIntent
            if let i = value as? InlinePresentationIntent { intent = i }
            else if let raw = value as? UInt { intent = InlinePresentationIntent(rawValue: raw) }
            else if let raw = value as? Int { intent = InlinePresentationIntent(rawValue: UInt(raw)) }
            else { return }
            if intent.contains(.code) {
                ns.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range: range)
            } else {
                ns.addAttribute(.font, value: traited(font,
                    bold: intent.contains(.stronglyEmphasized),
                    italic: intent.contains(.emphasized)), range: range)
            }
        }
        return ns
    }

    private static func traited(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        guard bold || italic else { return font }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
    }
}
