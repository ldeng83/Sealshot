import AppKit

/// Remembered "current" text-font family — the last one the user picked. Used as
/// the creation default for new text boxes and as the fallback when a loaded
/// `.seal` references a font that isn't installed. Persisted app-wide.
enum AnnotationTextFont {
    private static let key = "lastTextFontFamily"
    static var remembered: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let v = newValue, !v.isEmpty { UserDefaults.standard.set(v, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

/// True for the system-font sentinel (nil / empty / dotted internal name like
/// ".AppleSystemUIFont"). A run's `fontFamily` is never one of these — nil means
/// "System / San Francisco".
func isSystemFontFamily(_ family: String?) -> Bool {
    guard let f = family, !f.isEmpty else { return true }
    return f.hasPrefix(".")
}

/// Whether `family` names a real, installed font family (not System, not missing).
func textFontFamilyIsAvailable(_ family: String) -> Bool {
    !isSystemFontFamily(family) && NSFontManager.shared.availableFontFamilies.contains(family)
}

/// Custom run attribute recording the semantic base `TextWeight` (rawValue as
/// NSNumber). Weight can't be reliably recovered from a concrete NSFont once
/// Bold emphasis is also applied, so it travels alongside the font and is the
/// source of truth on read-back.
let textWeightAttributeKey = NSAttributedString.Key("sealTextWeight")

/// Horizontal padding (image-space points) inset on EACH side of a text box, so
/// the text and caret don't sit flush against the box edge. Applied consistently
/// by the sizer (the box fits text + 2·pad), the inline editor (text-container
/// inset), and the renderer (layout rect inset) so editing and committed render
/// agree. The text wrap width is therefore `boxWidth − 2·textBoxHPadding`.
let textBoxHPadding: CGFloat = 4

/// `NSFont.Weight` for the system-font path.
private func systemFontWeight(_ w: TextWeight?) -> NSFont.Weight {
    switch w {
    case .none, .regular: return .regular
    case .ultralight:     return .ultraLight
    case .light:          return .light
    case .medium:         return .medium
    case .semibold:       return .semibold
    case .bold:           return .bold
    case .heavy:          return .heavy
    case .black:          return .black
    }
}

/// The NSFont for a run: its own family when installed; else the remembered
/// fallback family; else the system font. Weight/bold/italic/size all apply
/// (Bold adds emphasis on top of the chosen weight).
func annotationTextFont(family: String?, size: CGFloat, isBold: Bool,
                        weight: TextWeight? = nil, isItalic: Bool = false) -> NSFont {
    // Bold emphasis folds into the weight ("at least bold") so the Weight control
    // and the Bold toggle don't fight over the same axis. The family member
    // closest to this weight is what gets used (limited by what the font ships).
    let requested = systemFontWeight(weight)
    let effective = isBold ? NSFont.Weight(rawValue: max(requested.rawValue, NSFont.Weight.bold.rawValue)) : requested

    func systemFont() -> NSFont {
        var base = NSFont.systemFont(ofSize: size, weight: effective)
        if isItalic { base = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) }
        return base
    }
    // Resolve to an installed named family (or the remembered fallback); else System.
    let installed = Set(NSFontManager.shared.availableFontFamilies)
    let resolved: String? = {
        if let family, !isSystemFontFamily(family), installed.contains(family) { return family }
        if let rem = AnnotationTextFont.remembered, !isSystemFontFamily(rem), installed.contains(rem) { return rem }
        return nil
    }()
    guard let family = resolved else { return systemFont() }

    // Ask the font-matching system for the family member closest to `effective`
    // via a descriptor weight trait — more reliable across fonts than the legacy
    // NSFontManager weight-step API — then layer italic as a symbolic trait.
    var desc = NSFontDescriptor(fontAttributes: [
        .family: family,
        .traits: [NSFontDescriptor.TraitKey.weight: effective.rawValue],
    ])
    if isItalic { desc = desc.withSymbolicTraits(.italic) }
    return NSFont(descriptor: desc, size: size) ?? NSFont(name: family, size: size) ?? systemFont()
}

/// The NSFont for a run at `scale`.
func annotationTextFont(for run: TextRun, scale: CGFloat = 1) -> NSFont {
    annotationTextFont(family: run.fontFamily, size: run.fontSize * scale,
                       isBold: run.isBold, weight: run.weight, isItalic: run.isItalic)
}

/// Map a concrete font back to a storable family (nil = System default).
func storableTextFamily(of font: NSFont) -> String? {
    let fam = font.familyName ?? ""
    return isSystemFontFamily(fam) ? nil : fam
}

/// Distinct non-system font families referenced by `annotations`' text that are
/// NOT installed on this Mac — drives the "font missing" warning on load.
func missingTextFontFamilies(in annotations: [Annotation]) -> [String] {
    let available = Set(NSFontManager.shared.availableFontFamilies)
    var seen = Set<String>(), missing: [String] = []
    for a in annotations {
        guard case let .text(_, runs) = a.geometry else { continue }
        for run in runs {
            guard let fam = run.fontFamily, !isSystemFontFamily(fam), seen.insert(fam).inserted else { continue }
            if !available.contains(fam) { missing.append(fam) }
        }
    }
    return missing
}

/// Paint pass for outlined text (CSS `paint-order: stroke fill` semantics).
/// A single-pass centered stroke (negative `strokeWidth`) eats the glyph's
/// own fill from the inside and paints over the PREVIOUS glyph's fill where
/// fat outlines overlap — so outlined text draws in TWO passes: all strokes
/// first, all fills on top, making the outline expand strictly outward.
/// `.single` is the legacy one-pass mode: non-outlined text, and the live
/// NSTextView editor (which cannot two-pass its typing attributes — while
/// editing, outlines show the centered-stroke approximation and the correct
/// paint order appears on commit).
enum TextPaintPass {
    case single, stroke, fill
}

/// Whether any run carries an outline — the trigger for two-pass drawing.
func textRunsHaveOutline(_ runs: [TextRun]) -> Bool {
    runs.contains { $0.outlineColor != nil }
}

/// The full attribute dictionary for one run: font (family/size/weight/bold/
/// italic), color (× opacity), underline, strikethrough, highlight background,
/// and outline stroke. Shared by the renderer, the inline editor's typing
/// attributes, and empty-box measurement so every surface stays consistent.
///
/// Per pass: `.stroke` draws highlight backgrounds (bottom-most) and
/// stroke-only glyphs at DOUBLE the outline width (the stroke is centered on
/// the glyph path, so half falls outside — the inner half is covered by the
/// fill pass); non-outlined runs are invisible placeholders that keep layout
/// identical. `.fill` draws everything except backgrounds and strokes.
func runAttributes(for run: TextRun, opacity: Double, scale: CGFloat,
                   paragraph: NSParagraphStyle,
                   pass: TextPaintPass = .single) -> [NSAttributedString.Key: Any] {
    var attrs: [NSAttributedString.Key: Any] = [
        .font: annotationTextFont(for: run, scale: scale),
        .foregroundColor: applyOpacity(run.color.nsColor, opacity: opacity),
        .paragraphStyle: paragraph,
    ]
    // Weight travels as a custom attribute (see `textWeightAttributeKey`).
    if let w = run.weight { attrs[textWeightAttributeKey] = NSNumber(value: w.rawValue) }

    switch pass {
    case .single:
        if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let hi = run.highlight { attrs[.backgroundColor] = applyOpacity(hi.nsColor, opacity: opacity) }
        if let oc = run.outlineColor {
            attrs[.strokeColor] = applyOpacity(oc.nsColor, opacity: opacity)
            // Negative = stroke AND fill in one pass (legacy / live editor).
            // Width is a percentage of font size, so it scales with large text.
            attrs[.strokeWidth] = -abs(run.outlineWidth)
        }
    case .stroke:
        attrs[.foregroundColor] = NSColor.clear   // placeholders keep layout; no fills
        if let hi = run.highlight { attrs[.backgroundColor] = applyOpacity(hi.nsColor, opacity: opacity) }
        if let oc = run.outlineColor {
            attrs[.strokeColor] = applyOpacity(oc.nsColor, opacity: opacity)
            // Positive = stroke ONLY; doubled because the stroke is centered
            // and its inner half is covered by the fill pass.
            attrs[.strokeWidth] = 2 * abs(run.outlineWidth)
        }
    case .fill:
        if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        // No background (drawn beneath the strokes in the stroke pass) and no
        // stroke attributes — plain fill over the stroke pass.
    }
    return attrs
}

/// `NSTextAlignment` for a `TextAlignment`.
func nsTextAlignment(_ a: TextAlignment) -> NSTextAlignment {
    switch a { case .left: return .left; case .center: return .center; case .right: return .right }
}

/// The x-origin of a masked text box's layout rect. The layout rect (whose width
/// is the frozen `textLayoutWidth`) is anchored to the box edge the text aligns
/// to, so right/center-aligned text stays pinned to the box's right/center edge —
/// extending LEFT into the box's empty space — instead of overflowing (and being
/// clipped) past the box's right edge. Left alignment keeps the box's left edge.
func textLayoutOriginX(alignment: TextAlignment, boxMinX: CGFloat, boxMaxX: CGFloat, layoutWidth: CGFloat) -> CGFloat {
    switch alignment {
    case .left:   return boxMinX
    case .right:  return boxMaxX - layoutWidth
    case .center: return (boxMinX + boxMaxX) / 2 - layoutWidth / 2
    }
}

/// Inset a box `rect` so a `contentHeight`-tall text block sits at the top /
/// middle / bottom of it. `NSAttributedString.draw(in:)` always fills from the
/// rect's top edge, so we shrink the rect from the top by the vertical gap —
/// which is +minY in a flipped (y-down) context and −height in a y-up one.
func verticalAlignedRect(_ rect: CGRect, contentHeight: CGFloat,
                         vAlign: TextVerticalAlignment, flipped: Bool) -> CGRect {
    let extra = max(0, rect.height - contentHeight)
    let topGap: CGFloat = vAlign == .top ? 0 : (vAlign == .middle ? extra / 2 : extra)
    guard topGap > 0 else { return rect }
    return flipped
        ? CGRect(x: rect.minX, y: rect.minY + topGap, width: rect.width, height: rect.height - topGap)
        : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - topGap)
}

/// Build `runs` into one attributed string with paragraph-level `alignment` and
/// `lineSpacing` (image-space points, scaled). Shared by the live canvas
/// (scaled), the export renderer (scale 1), and the inline editor.
func attributedString(for runs: [TextRun], opacity: Double, scale: CGFloat = 1,
                      alignment: TextAlignment = .left, lineSpacing: CGFloat = 0,
                      pass: TextPaintPass = .single) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.alignment = nsTextAlignment(alignment)
    paragraph.lineSpacing = max(0, lineSpacing) * scale
    let out = NSMutableAttributedString()
    for run in runs {
        out.append(NSAttributedString(string: run.text,
                                      attributes: runAttributes(for: run, opacity: opacity,
                                                                scale: scale, paragraph: paragraph,
                                                                pass: pass)))
    }
    return out
}

/// Convert an edited attributed string back to runs — one run per maximal span
/// of equal (color, size, bold). `defaultColor` is used if a span lacks a
/// foreground color. Sizes are read at face value (scale 1); callers editing at
/// a zoom scale must divide out the scale before storing.
func runs(from attributed: NSAttributedString, defaultColor: SerializableColor) -> [TextRun] {
    var result: [TextRun] = []
    let full = NSRange(location: 0, length: attributed.length)
    attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
        let text = (attributed.string as NSString).substring(with: range)
        guard !text.isEmpty else { return }
        let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 18)
        let traits = font.fontDescriptor.symbolicTraits
        let color: SerializableColor = {
            if let c = attrs[.foregroundColor] as? NSColor { return SerializableColor(opaqueSRGB(c)) }
            return defaultColor
        }()
        let weight = (attrs[textWeightAttributeKey] as? NSNumber).flatMap { TextWeight(rawValue: $0.intValue) }
        let highlight = (attrs[.backgroundColor] as? NSColor).map { SerializableColor(opaqueSRGB($0)) }
        let outlineColor = (attrs[.strokeColor] as? NSColor).map { SerializableColor(opaqueSRGB($0)) }
        let outlineWidth = abs((attrs[.strokeWidth] as? CGFloat) ?? 6)
        let run = TextRun(
            text: text, color: color, fontSize: font.pointSize, isBold: traits.contains(.bold),
            fontFamily: storableTextFamily(of: font), weight: weight, isItalic: traits.contains(.italic),
            underline: (attrs[.underlineStyle] as? Int ?? 0) != 0,
            strikethrough: (attrs[.strikethroughStyle] as? Int ?? 0) != 0,
            highlight: highlight, outlineColor: outlineColor, outlineWidth: outlineWidth)
        if var last = result.last, last.stylesMatch(run) {
            last.text += run.text
            result[result.count - 1] = last
        } else {
            result.append(run)
        }
    }
    return result
}

/// Clamp a dragged text-box rect so its height is at least the content height
/// for its width. If too short, grow to content height keeping one edge anchored:
/// `anchorBottom == true` keeps the bottom fixed (grows upward), else keeps the
/// top fixed (grows downward). A box taller than its content is left unchanged.
/// `layoutWidth` is the width runs actually wrap to; it defaults to `rect.width`
/// when omitted. STYLE-edit callers on a box that may be narrower than its
/// true wrap width must pass the box's `effectiveTextLayoutWidth` explicitly,
/// so the grow-only clamp measures against the true (possibly wider) layout
/// width instead of re-wrapping — and growing — at the narrower visible rect.
/// The live manual-resize drag deliberately does NOT clamp at all: under the
/// mask model, resizing is free and the rect simply hides overflowing text.
func clampTextHeight(rect: CGRect, runs: [TextRun], anchorBottom: Bool, lineSpacing: CGFloat = 0,
                      layoutWidth: CGFloat? = nil) -> CGRect {
    let content = textBoxHeight(runs: runs, width: layoutWidth ?? rect.width, lineSpacing: lineSpacing)
    guard rect.height < content else { return rect }
    let minY = anchorBottom ? rect.maxY - content : rect.minY
    return CGRect(x: rect.minX, y: minY, width: rect.width, height: content)
}

/// Height (image space, scale 1) to lay `runs` out wrapped to `width`. Empty
/// runs reserve one line at the standard size so an empty box stays visible.
func textBoxHeight(runs: [TextRun], width: CGFloat, lineSpacing: CGFloat = 0) -> CGFloat {
    let attributed: NSAttributedString = runs.isEmpty
        ? NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 18)])
        : attributedString(for: runs, opacity: 1.0, lineSpacing: lineSpacing)
    let bounding = attributed.boundingRect(
        with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return ceil(bounding.height)
}
