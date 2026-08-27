import AppKit

/// Inline, on-canvas rich-text editor backed by an `NSTextView`. Owned by
/// `EditorCanvasView`. Works in image-space font sizes: it captures the canvas
/// `scale` at configure time, applies `imageSize * scale` to the text view, and
/// divides the scale back out when reporting sizes / producing runs. Holds a
/// private `UndoManager` so ⌘Z while typing reverts text, not annotation history.
@MainActor
final class InlineTextEditor: NSObject, NSTextViewDelegate {

    let textView: NSTextView
    private let textUndo = UndoManager()
    private var scale: CGFloat = 1
    private var boxOpacity: Double = 1
    private var defaultColor: SerializableColor = SerializableColor(r: 0, g: 0, b: 0, a: 1)
    private var boxAlignment: TextAlignment = .left
    private var boxLineSpacing: CGFloat = 0
    private var boxVerticalAlignment: TextVerticalAlignment = .top

    // Box-level readouts for the styling panel (alignment/line-spacing preview
    // live; vertical-align and opacity take effect on commit).
    var alignment: TextAlignment { boxAlignment }
    var lineSpacing: CGFloat { boxLineSpacing }
    var verticalAlignment: TextVerticalAlignment { boxVerticalAlignment }
    var opacity: Double { boxOpacity }

    /// Idle gap after which the next keystroke starts a new undo chunk
    /// (typing-pause boundary for smart undo). Injectable for tests.
    var typingChunkInterval: TimeInterval = 0.8

    /// Fires on every text change so the canvas can auto-grow the box height.
    var onChange: (() -> Void)?
    /// Fires when editing should end (Esc).
    var onCommit: (() -> Void)?
    /// Fires when the selection or its attributes change, so a styling panel can refresh.
    var onSelectionChange: (() -> Void)?

    override init() {
        textView = NSTextView(frame: .zero)
        super.init()
        // Chunk groups are managed EXPLICITLY (see "Smart undo chunking"):
        // AppKit's per-event grouping + typing coalescing otherwise merge an
        // entire editing burst into one undo step.
        textUndo.groupsByEvent = false
        textView.delegate = self
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.focusRingType = .none
        textView.usesFontPanel = false
        // Translucent selection background with no foreground override, so the
        // glyphs keep their own color while selected — the highlight only marks
        // the range. (The default opaque selection color hides color edits until
        // the user deselects.)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)
        ]
    }

    /// Position + seed the editor. `runs` (image-space sizes) are scaled by
    /// `scale` for display; `defaultRun` provides the typing attributes for an
    /// empty box / new typing.
    func configure(frame: NSRect, runs: [TextRun], defaultRun: TextRun,
                   opacity: Double, scale: CGFloat, wrapWidth: CGFloat,
                   alignment: TextAlignment = .left, lineSpacing: CGFloat = 0,
                   verticalAlignment: TextVerticalAlignment = .top) {
        self.scale = scale
        self.boxOpacity = opacity
        self.defaultColor = defaultRun.color
        self.boxAlignment = alignment
        self.boxLineSpacing = lineSpacing
        self.boxVerticalAlignment = verticalAlignment
        // Fresh session: no chunk in flight, no undo leakage across edits.
        closeChunk()
        textUndo.removeAllActions()
        textView.frame = frame
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
        // Horizontal padding: inset the text container so the caret/text clear
        // the box edges (matches the renderer's layout-rect inset). The text
        // wraps within the padded width.
        let hPad = textBoxHPadding * scale
        textView.textContainerInset = NSSize(width: hPad, height: 0)
        textView.textContainer?.containerSize = NSSize(width: max(1, wrapWidth - 2 * hPad), height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        if runs.isEmpty {
            textView.textStorage?.setAttributedString(NSAttributedString(string: "", attributes: typingAttrs(for: defaultRun)))
            textView.typingAttributes = typingAttrs(for: defaultRun)
        } else {
            textView.textStorage?.setAttributedString(
                attributedString(for: runs, opacity: opacity, scale: scale,
                                 alignment: alignment, lineSpacing: lineSpacing))
            textView.typingAttributes = typingAttrs(for: runs.last!)
        }
    }

    /// Re-scale displayed glyph sizes when the canvas scale changes mid-edit
    /// (e.g. window resize), preserving rich per-run styling, and update the
    /// wrap width. No-op (apart from wrap width) when the scale is unchanged.
    func updateScale(_ newScale: CGFloat, wrapWidth: CGFloat) {
        defer {
            textView.maxSize = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
            let hPad = textBoxHPadding * newScale
            textView.textContainerInset = NSSize(width: hPad, height: 0)
            textView.textContainer?.containerSize = NSSize(width: max(1, wrapWidth - 2 * hPad), height: .greatestFiniteMagnitude)
        }
        guard newScale > 0, newScale != scale, let s = textView.textStorage else { return }
        let factor = newScale / scale
        s.beginEditing()
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length), options: []) { value, range, _ in
            if let f = value as? NSFont {
                s.addAttribute(.font, value: f.resized(to: f.pointSize * factor), range: range)
            }
        }
        s.endEditing()
        if let tf = textView.typingAttributes[.font] as? NSFont {
            textView.typingAttributes[.font] = tf.resized(to: tf.pointSize * factor)
        }
        scale = newScale
    }

    private func typingAttrs(for run: TextRun) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping
        p.alignment = nsTextAlignment(boxAlignment)
        p.lineSpacing = max(0, boxLineSpacing) * scale
        return runAttributes(for: run, opacity: boxOpacity, scale: scale, paragraph: p)
    }

    /// Runs in image space (font sizes divided back by `scale`, colors made
    /// opaque — box opacity is applied at render, not stored per run). Named
    /// `currentRuns` (not `runs`) so it doesn't shadow the free `runs(from:)`.
    var currentRuns: [TextRun] {
        guard let storage = textView.textStorage, storage.length > 0 else { return [] }
        let scaled = runs(from: storage, defaultColor: defaultColor)
        return scaled.map { var r = $0; r.fontSize /= scale; return r }   // image-space size
    }

    var isEmpty: Bool {
        textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Selection styling (sizes are image-space)
    private var selectedRange: NSRange { textView.selectedRange() }

    // These apply to the current selection from a sidebar control the user is
    // operating, so they deliberately do NOT fire `onSelectionChange`: that
    // would rebuild the styling panel and tear a live control (e.g. the
    // font-size slider) out of the view tree mid-drag. The panel only refreshes
    // when the selection itself moves (`textViewDidChangeSelection`).
    func applyColor(_ color: NSColor) {
        let c = applyOpacity(opaqueSRGB(color), opacity: boxOpacity)
        mutate { $0.addAttribute(.foregroundColor, value: c, range: $1) }
        textView.typingAttributes[.foregroundColor] = c
    }
    func applyFontSize(_ imageSize: CGFloat) {
        mutateFont { $0.resized(to: imageSize * self.scale) }
    }
    func setBold(_ bold: Bool) {
        mutateFont { NSFontManager.shared.convert($0, toHaveTrait: bold ? .boldFontMask : .unboldFontMask) }
    }
    /// Change the font family of the selection (and typing), preserving size and
    /// bold. `nil` = System. Missing families never reach here (picked from the
    /// installed list); an unresolvable convert leaves the font unchanged.
    func applyFontFamily(_ family: String?) {
        mutateFont { f in
            let bold = f.isBoldWeight
            if let family, !isSystemFontFamily(family) {
                return annotationTextFont(family: family, size: f.pointSize, isBold: bold)
            }
            return NSFont.systemFont(ofSize: f.pointSize, weight: bold ? .bold : .regular)
        }
    }

    // — Parity styling: weight, emphasis, highlight, outline, box align/spacing —

    func applyWeight(_ w: TextWeight?) {
        mutateFont { f in
            annotationTextFont(family: storableTextFamily(of: f), size: f.pointSize,
                               isBold: f.fontDescriptor.symbolicTraits.contains(.bold),
                               weight: w, isItalic: f.fontDescriptor.symbolicTraits.contains(.italic))
        }
        setAttr(textWeightAttributeKey, w.map { NSNumber(value: $0.rawValue) })
    }
    func setItalic(_ italic: Bool) {
        mutateFont { NSFontManager.shared.convert($0, toHaveTrait: italic ? .italicFontMask : .unitalicFontMask) }
    }
    func setUnderline(_ on: Bool) { setAttr(.underlineStyle, on ? NSUnderlineStyle.single.rawValue : nil) }
    func setStrikethrough(_ on: Bool) { setAttr(.strikethroughStyle, on ? NSUnderlineStyle.single.rawValue : nil) }
    func applyHighlight(_ color: NSColor?) {
        setAttr(.backgroundColor, color.map { applyOpacity(opaqueSRGB($0), opacity: boxOpacity) })
    }
    func applyOutline(_ color: NSColor?) {
        if let color {
            setAttr(.strokeColor, applyOpacity(opaqueSRGB(color), opacity: boxOpacity))
            setAttr(.strokeWidth, -abs(currentOutlineWidth))
        } else {
            setAttr(.strokeColor, nil)
            setAttr(.strokeWidth, nil)
        }
    }
    func applyOutlineWidth(_ pct: CGFloat) {
        // Only meaningful with an outline color; still remember for typing so a
        // later outline pick uses this width.
        if uniformAttribute(.strokeColor) != nil {
            setAttr(.strokeWidth, -abs(pct))
        } else {
            textView.typingAttributes[.strokeWidth] = -abs(pct)
        }
    }
    func setAlignment(_ a: TextAlignment) { boxAlignment = a; reapplyParagraph() }
    func setLineSpacing(_ ls: CGFloat) { boxLineSpacing = max(0, ls); reapplyParagraph() }
    func setVerticalAlignment(_ v: TextVerticalAlignment) { boxVerticalAlignment = v; onChange?() }
    func setOpacity(_ o: Double) { boxOpacity = o; onChange?() }   // applied on commit

    /// Set (or remove, when `value` is nil) one attribute across the selection,
    /// and mirror it into the typing attributes so new text inherits it.
    private func setAttr(_ key: NSAttributedString.Key, _ value: Any?) {
        mutate { s, r in
            if let value { s.addAttribute(key, value: value, range: r) }
            else { s.removeAttribute(key, range: r) }
        }
        if let value { textView.typingAttributes[key] = value }
        else { textView.typingAttributes.removeValue(forKey: key) }
    }

    private var currentOutlineWidth: CGFloat {
        if let sw = uniformAttribute(.strokeWidth) as? CGFloat { return abs(sw) }
        if let sw = textView.typingAttributes[.strokeWidth] as? CGFloat { return abs(sw) }
        return 6
    }

    private func reapplyParagraph() {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.alignment = nsTextAlignment(boxAlignment)
        p.lineSpacing = max(0, boxLineSpacing) * scale
        if let s = textView.textStorage {
            let full = NSRange(location: 0, length: s.length)
            if full.length > 0, textView.shouldChangeText(in: full, replacementString: nil) {
                s.beginEditing(); s.addAttribute(.paragraphStyle, value: p, range: full); s.endEditing()
                textView.didChangeText()
            }
        }
        textView.typingAttributes[.paragraphStyle] = p
        onChange?()
    }

    /// The range a sidebar style control applies to: the explicit selection when
    /// there is one, else the WHOLE box. Styling with just a cursor (no selection)
    /// restyles all the text — matching the intuition that the panel styles "this
    /// text box" — instead of silently affecting only future typing. Select a span
    /// to style just part of it (rich text).
    private func styleTargetRange(_ s: NSTextStorage) -> NSRange {
        let sel = selectedRange
        return sel.length > 0 ? sel : NSRange(location: 0, length: s.length)
    }

    private func mutate(_ body: (NSTextStorage, NSRange) -> Void) {
        guard let s = textView.textStorage else { return }
        closeChunk()   // style edits are their own undo chunk
        let r = styleTargetRange(s)
        if r.length > 0, textView.shouldChangeText(in: r, replacementString: nil) {
            s.beginEditing(); body(s, r); s.endEditing()
            textView.didChangeText()
        }
        closeChunk()
        onChange?()
    }
    private func mutateFont(_ make: (NSFont) -> NSFont) {
        guard let s = textView.textStorage else { return }
        closeChunk()   // style edits are their own undo chunk
        let r = styleTargetRange(s)
        if r.length > 0, textView.shouldChangeText(in: r, replacementString: nil) {
            s.beginEditing()
            s.enumerateAttribute(.font, in: r, options: []) { value, range, _ in
                let f = (value as? NSFont) ?? NSFont.systemFont(ofSize: 18 * self.scale)
                s.addAttribute(.font, value: make(f), range: range)
            }
            s.endEditing()
            textView.didChangeText()
        }
        closeChunk()
        let typingFont = (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 18 * scale)
        textView.typingAttributes[.font] = make(typingFont)
        onChange?()
    }

    // MARK: Current-selection readout (image space); nil = mixed/none
    var selectionFontSize: CGFloat? {
        guard let f = uniformAttribute(.font) as? NSFont else { return nil }
        return f.pointSize / scale
    }
    var selectionIsBold: Bool? {
        guard let f = uniformAttribute(.font) as? NSFont else { return nil }
        return f.fontDescriptor.symbolicTraits.contains(.bold)
    }
    /// Selected family (nil = System / mixed handled by caller). `.some(nil)`
    /// distinguishes "uniformly System" from "mixed"; a nil font means mixed.
    var selectionFontFamily: String?? {
        guard let f = uniformAttribute(.font) as? NSFont else { return nil }
        return storableTextFamily(of: f)
    }
    var selectionColor: NSColor? { uniformAttribute(.foregroundColor) as? NSColor }
    var selectionWeight: TextWeight? {
        (uniformAttribute(textWeightAttributeKey) as? NSNumber).flatMap { TextWeight(rawValue: $0.intValue) }
    }
    var selectionIsItalic: Bool {
        (uniformAttribute(.font) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
    }
    var selectionUnderline: Bool { ((uniformAttribute(.underlineStyle) as? Int) ?? 0) != 0 }
    var selectionStrikethrough: Bool { ((uniformAttribute(.strikethroughStyle) as? Int) ?? 0) != 0 }
    var selectionHighlight: NSColor? { (uniformAttribute(.backgroundColor) as? NSColor).map { opaqueSRGB($0) } }
    var selectionOutlineColor: NSColor? { (uniformAttribute(.strokeColor) as? NSColor).map { opaqueSRGB($0) } }
    var selectionOutlineWidth: CGFloat { currentOutlineWidth }

    /// A `TextRun` describing the CURRENT typing attributes — what the next typed
    /// character would look like. Used to remember creation defaults when a box
    /// is committed empty (no runs exist yet, but the user may have adjusted the
    /// panel). Colors are opaque (box opacity is a separate box-level value); the
    /// size is image-space, matching `currentRuns`.
    var currentTypingRun: TextRun {
        let opaque = selectionColor.map { opaqueSRGB($0) }
        let family: String? = selectionFontFamily ?? nil
        return TextRun(
            text: "",
            color: SerializableColor(opaque ?? defaultColor.nsColor),
            fontSize: selectionFontSize ?? 18,
            isBold: selectionIsBold ?? false,
            fontFamily: family,
            weight: selectionWeight,
            isItalic: selectionIsItalic,
            underline: selectionUnderline,
            strikethrough: selectionStrikethrough,
            highlight: selectionHighlight.map { SerializableColor($0) },
            outlineColor: selectionOutlineColor.map { SerializableColor($0) },
            outlineWidth: selectionOutlineWidth)
    }

    private func uniformAttribute(_ key: NSAttributedString.Key) -> Any? {
        guard let s = textView.textStorage else { return nil }
        let r = selectedRange
        if r.length == 0 { return textView.typingAttributes[key] }
        var values: [NSObject?] = []
        s.enumerateAttribute(key, in: r, options: []) { v, _, _ in values.append(v as? NSObject) }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    // Undo/clipboard helpers used by the window while editing.
    func performUndo() {
        closeChunk()   // ⌘Z undoes the chunk in flight first
        if textUndo.canUndo { textUndo.undo() }
    }
    func performRedo() {
        closeChunk()
        if textUndo.canRedo { textUndo.redo() }
    }
    func selectAllText() { textView.selectAll(nil) }
    func copyText() { textView.copy(nil) }
    func cutText() { textView.cut(nil) }
    func pasteText() { textView.pasteAsPlainText(nil) }

    // MARK: Smart undo chunking

    /// AppKit coalesces an entire uninterrupted typing burst into ONE undo
    /// group, so ⌘Z nuked the whole paragraph. Instead, chunk groups are
    /// managed explicitly (`groupsByEvent` off): a group opens with the first
    /// change and closes at natural boundaries — a word delimiter, a typing
    /// pause, a style edit, or ⌘Z itself — so undo peels chunks like a
    /// modern text box. `breakUndoCoalescing` at every close stops the
    /// typing coalescer from extending an operation inside a closed group.
    /// (`updateScale`'s storage rewrite bypasses the should/didChange path,
    /// so it never touches the undo stack.)
    private var chunkOpen = false
    private var chunkBreakTimer: Timer?
    /// Set when the change being applied ends a chunk (a delimiter keystroke);
    /// the chunk closes in `textDidChange`, AFTER the delimiter registers, so
    /// ⌘Z peels "word + delimiter" — an invisible lone-delimiter chunk would
    /// read as "undo did nothing".
    private var pendingChunkBoundary = false

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        // NSTextView re-enters this while APPLYING an undo/redo. Opening a
        // chunk group mid-replay corrupts the undo manager (field bug: after
        // undoing to empty, typing went dead) — never manage groups here.
        guard !textUndo.isUndoing, !textUndo.isRedoing else { return true }
        if !chunkOpen {
            textUndo.beginUndoGrouping()
            chunkOpen = true
        }
        if let s = replacementString, !s.isEmpty,
           s.unicodeScalars.contains(where: {
               CharacterSet.whitespacesAndNewlines.contains($0)
                   || CharacterSet.punctuationCharacters.contains($0)
           }) {
            pendingChunkBoundary = true
        }
        return true
    }

    private func closeChunk() {
        chunkBreakTimer?.invalidate()
        pendingChunkBoundary = false
        textView.breakUndoCoalescing()
        guard chunkOpen else { return }
        textUndo.endUndoGrouping()
        chunkOpen = false
    }

    private func scheduleChunkBreak() {
        chunkBreakTimer?.invalidate()
        chunkBreakTimer = Timer.scheduledTimer(withTimeInterval: typingChunkInterval,
                                               repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeChunk() }
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { textUndo }
    func textDidChange(_ notification: Notification) {
        if textUndo.isUndoing || textUndo.isRedoing {
            onChange?()
            return
        }
        if pendingChunkBoundary {
            closeChunk()
        } else {
            scheduleChunkBreak()
        }
        onChange?()
    }
    func textViewDidChangeSelection(_ notification: Notification) { onSelectionChange?() }
}

private extension NSFont {
    var isBoldWeight: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    /// New size, same family + traits (preserves a custom font under zoom/resize).
    func resized(to size: CGFloat) -> NSFont {
        NSFont(descriptor: fontDescriptor, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: isBoldWeight ? .bold : .regular)
    }
}
