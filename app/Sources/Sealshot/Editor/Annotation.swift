import AppKit
import CoreGraphics

/// A user-drawn annotation on top of the captured image. Coordinates are in
/// image space (origin at top-left of the *currently visible* image, units in
/// pixels). When a crop is committed, annotation coordinates are translated
/// so this invariant always holds.
///
/// `id` is stable across the annotation's lifetime — it's used by the
/// selection model (`EditorState.selectedAnnotationIDs` / `primarySelectionID`) and by the codec
/// (so re-opening a saved file preserves identity for undo/redo continuity).
///
/// The shape is split into `geometry` (the points/rect that define where the
/// annotation lives) and `style` (the editable visual properties shared by
/// every shape). This lets the UI mutate appearance independently of position.
struct Annotation: Identifiable, Equatable, Codable {
    let id: UUID
    var geometry: Geometry
    var style: Style
    var transform: AnnotationTransform

    init(id: UUID = UUID(), geometry: Geometry, style: Style,
         transform: AnnotationTransform = AnnotationTransform()) {
        self.id = id
        self.geometry = geometry
        self.style = style
        self.transform = transform
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey { case id, geometry, style, transform }

    /// Custom decoder so older files (written before `transform` existed) decode
    /// to identity transform instead of throwing. The encoder stays synthesized
    /// (via CodingKeys), so new files always include the `transform` key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        geometry = try c.decode(Geometry.self, forKey: .geometry)
        style = try c.decode(Style.self, forKey: .style)
        transform = try c.decodeIfPresent(AnnotationTransform.self, forKey: .transform)
            ?? AnnotationTransform()
    }
}

/// Discrete base font weight for a text run (`nil` = the family's default).
/// AppKit-free — `TextRendering` maps each case to an `NSFontManager` weight
/// step. The Bold flag applies emphasis on top of the chosen weight.
enum TextWeight: Int, Codable, Equatable, CaseIterable {
    case ultralight, light, regular, medium, semibold, bold, heavy, black
}

/// One styled span of a text box. Text boxes store `[TextRun]` so every character
/// attribute (color, font, weight, bold/italic/underline/strikethrough,
/// highlight, outline) can vary within a single box (rich text). `opacity` is NOT
/// here — it stays box-level on `Style` and multiplies every run's color.
struct TextRun: Equatable, Codable {
    var text: String
    /// The run's base text color — always fully opaque. Box-level opacity lives
    /// on `Style.opacity` and is multiplied in only at render time; `runs(from:)`
    /// strips it back out so this stays opaque.
    var color: SerializableColor
    var fontSize: CGFloat
    var isBold: Bool
    /// Font family name (e.g. "Helvetica Neue"). `nil` = the system font (San
    /// Francisco), which is also the back-compat default for pre-font `.seal`
    /// files. The stored name is never rewritten on load, so a file opened on a
    /// Mac that lacks the font falls back at render time yet still renders
    /// correctly when reopened where the font exists.
    var fontFamily: String? = nil
    /// Base weight (nil = family default). Bold applies emphasis on top.
    var weight: TextWeight? = nil
    var isItalic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    /// Highlighter color painted behind the glyphs (nil = none).
    var highlight: SerializableColor? = nil
    /// Outline stroke color (nil = no outline). `outlineWidth` is a percentage of
    /// the font size, so the outline scales with large text.
    var outlineColor: SerializableColor? = nil
    var outlineWidth: CGFloat = 6

    init(text: String, color: SerializableColor, fontSize: CGFloat, isBold: Bool,
         fontFamily: String? = nil, weight: TextWeight? = nil, isItalic: Bool = false,
         underline: Bool = false, strikethrough: Bool = false,
         highlight: SerializableColor? = nil, outlineColor: SerializableColor? = nil,
         outlineWidth: CGFloat = 6) {
        self.text = text; self.color = color; self.fontSize = fontSize; self.isBold = isBold
        self.fontFamily = fontFamily; self.weight = weight; self.isItalic = isItalic
        self.underline = underline; self.strikethrough = strikethrough
        self.highlight = highlight; self.outlineColor = outlineColor; self.outlineWidth = outlineWidth
    }

    // Custom decode so older `.seal` files (written before these attributes) load
    // with neutral defaults — the synthesized decoder would throw on the missing
    // non-optional keys. Mirrors `Style`'s forward-compatible decoder.
    enum CodingKeys: String, CodingKey {
        case text, color, fontSize, isBold, fontFamily, weight
        case isItalic, underline, strikethrough, highlight, outlineColor, outlineWidth
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        color = try c.decode(SerializableColor.self, forKey: .color)
        fontSize = try c.decode(CGFloat.self, forKey: .fontSize)
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        weight = try c.decodeIfPresent(TextWeight.self, forKey: .weight)
        isItalic = try c.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        highlight = try c.decodeIfPresent(SerializableColor.self, forKey: .highlight)
        outlineColor = try c.decodeIfPresent(SerializableColor.self, forKey: .outlineColor)
        outlineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .outlineWidth) ?? 6
    }

    /// True when two runs share every style attribute (ignoring `text`), so
    /// adjacent equal-style spans merge into one run in `runs(from:)`.
    func stylesMatch(_ o: TextRun) -> Bool {
        color == o.color && fontSize == o.fontSize && isBold == o.isBold
            && fontFamily == o.fontFamily && weight == o.weight && isItalic == o.isItalic
            && underline == o.underline && strikethrough == o.strikethrough
            && highlight == o.highlight && outlineColor == o.outlineColor
            && (outlineColor == nil || outlineWidth == o.outlineWidth)
    }
}

/// The positional payload of an annotation — what is drawn and where. Carries
/// no appearance information; that lives in `Style`.
enum Geometry: Equatable, Codable {
    case arrow(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect)
    case text(rect: CGRect, runs: [TextRun])
    case ellipse(rect: CGRect)
    case line(start: CGPoint, end: CGPoint)
    case badge(center: CGPoint, radius: CGFloat)
    /// Freehand stroke: the raw drag path in image space, rendered as a
    /// rounded polyline. Uses Style stroke color/width/opacity only.
    case pen(points: [CGPoint])
    /// Freehand arrow: identical to `.pen` (same smoothed polyline, same
    /// per-vertex editing) but honors `Style.startCap`/`endCap`, drawing an
    /// arrowhead at each configured end oriented along the path's local tangent.
    case penArrow(points: [CGPoint])
    /// Blur/redaction region: the pixels inside `region` are obscured with the
    /// effect described by `Style.blurMode` / `Style.blurStrength`. Unlike the
    /// vector shapes this samples the source image rather than drawing a stroke.
    case blur(region: BlurRegion)
    /// A bitmap overlay: the image stored in the package as
    /// `asset-<assetID>.png`, drawn into `rect` (image space) with
    /// `Style.opacity`. Other Style fields are ignored.
    case image(rect: CGRect, assetID: String)
    /// A transparent "cut" hole: the pixels inside `rect` (image space) are
    /// removed — rendered with CGContext.clear on export (real alpha) and as a
    /// checkerboard on the live canvas. Behaves like `.rectangle` for geometry
    /// (bounds, translate, resize, hit-test, handles). Style is ignored.
    case cut(rect: CGRect)

    var isPen: Bool { if case .pen = self { return true }; return false }
    var isPenArrow: Bool { if case .penArrow = self { return true }; return false }
    /// A freehand stroke (pen OR free-arrow): both smooth the raw path and edit
    /// per-vertex, so callers that suppress vertex-dot clutter or resize via a
    /// bounding box treat them identically.
    var isFreehandStroke: Bool { isPen || isPenArrow }
    var isBlur: Bool { if case .blur = self { return true }; return false }
    /// A freehand brush blur — like `.pen`, it shows many per-vertex handles, so
    /// callers that suppress vertex-dot clutter on hover treat it the same way.
    var isFreehandBlur: Bool {
        if case .blur(.freehand) = self { return true }; return false
    }
    var isImage: Bool { if case .image = self { return true }; return false }
    var isCut: Bool { if case .cut = self { return true }; return false }
}

/// The shape of a blur region. Rectangle and ellipse store an axis-aligned
/// rect (image space); freehand stores the raw brush path plus a stroke
/// `width`, rendered as a rounded polyline mask (like the pen tool).
enum BlurRegion: Equatable, Codable, Hashable {
    case rect(CGRect)
    case ellipse(CGRect)
    case freehand(points: [CGPoint], width: CGFloat)

    /// Axis-aligned bounds in image space. For freehand the raw path bounds are
    /// inflated by half the brush width so the rounded stroke is fully enclosed.
    var boundingRect: CGRect {
        switch self {
        case let .rect(r), let .ellipse(r):
            return r.standardized
        case let .freehand(points, width):
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    /// Translate the region by `(dx, dy)` (used on crop commit).
    func offsetBy(dx: CGFloat, dy: CGFloat) -> BlurRegion {
        switch self {
        case let .rect(r): return .rect(r.offsetBy(dx: dx, dy: dy))
        case let .ellipse(r): return .ellipse(r.offsetBy(dx: dx, dy: dy))
        case let .freehand(points, width):
            return .freehand(points: points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, width: width)
        }
    }
}

/// How a blur region obscures its pixels. `pixelate` averages it into square
/// blocks; `mosaic` does the same with hexagonal cells; `gaussian` softens it;
/// `solid` fills it with an opaque block of `Style.fillColor` (instant — no Core
/// Image, strongest redaction). The strength (`Style.blurStrength`, 0…1) maps to
/// block size / blur radius via `BlurParams` and is ignored by `solid`.
enum BlurMode: String, Codable {
    case pixelate
    case mosaic
    case gaussian
    case solid
}

/// Which region shape the Blur tool draws next. A tool-level default on
/// `EditorState`; the concrete geometry is captured into a `BlurRegion` when the
/// annotation is created.
enum BlurRegionShape: String, CaseIterable {
    case rect
    case ellipse
    case freehand
}

/// A terminator drawn at one end of an arrow. `none` leaves the shaft bare;
/// `filled` is the classic solid triangle; `open` is a stroked V (barb); `dot`
/// is a filled disc; `bar` is a short perpendicular tee. Line annotations ignore
/// these (they always render bare); arrows read `Style.startCap`/`endCap`.
enum ArrowCap: String, Codable, CaseIterable {
    case none
    case filled
    case open
    case dot
    case bar
}

/// The shaft's width profile. `uniform` is the legacy constant-width stroke;
/// `tapered` fills a shaft that narrows along its length — wide at the arrow's
/// single head, or wide at the START when both ends (or neither) carry a cap,
/// the user-chosen rule for double-headed arrows. Straight arrows only: lines
/// and freehand (pen) arrows always render uniform.
enum ShaftStyle: String, Codable, CaseIterable {
    case uniform
    case tapered
}

/// The stroke pattern of a line/arrow shaft. `solid` is unbroken; the others lay
/// down a dash/dot pattern scaled to the stroke width. Read by both arrows and
/// lines via `Style.dashStyle`; arrowheads always render solid regardless.
enum DashStyle: String, Codable, CaseIterable {
    case solid
    case dashed
    case dotted
    case sparseDotted
}

/// Horizontal text alignment for a text box (paragraph-level). AppKit-free;
/// `TextRendering` maps it to `NSTextAlignment`.
enum TextAlignment: String, Codable, CaseIterable { case left, center, right }

/// Vertical placement of the text block within its (possibly taller) box.
enum TextVerticalAlignment: String, Codable, CaseIterable { case top, middle, bottom }

/// The editable visual properties shared by every annotation shape.
///
/// `opacity` multiplies into every color's alpha at render time. `fillColor`
/// is rectangle-only (nil = outline only). `cornerRadius` is rectangle-only
/// and is clamped to half the smaller side at render time so rounded corners
/// never overlap. The default style (opacity 1, no fill, corner 0) reproduces
/// the legacy appearance byte-for-byte.
struct Style: Equatable, Codable {
    var strokeColor: SerializableColor
    var strokeWidth: CGFloat
    var opacity: Double
    var fillColor: SerializableColor?
    var cornerRadius: CGFloat
    /// Text-only: point size of the text box's font (image space). Ignored by
    /// arrow/rectangle. Default reproduces the standard text size.
    var fontSize: CGFloat
    /// Text-only: bold weight when true. Ignored by arrow/rectangle.
    var isBold: Bool
    /// Blur-only: which effect obscures the region. Ignored by every other shape.
    var blurMode: BlurMode
    /// Blur-only: effect strength, normalized 0…1. Mapped to a concrete block
    /// size / blur radius by `BlurParams`. Ignored by every other shape.
    var blurStrength: Double
    /// Arrow-only: terminator at the shaft's start point. Lines ignore it.
    /// Default `.none` reproduces the legacy single-headed arrow.
    var startCap: ArrowCap
    /// Arrow-only: terminator at the shaft's end point. Lines ignore it.
    /// Default `.filled` reproduces the legacy single-headed arrow.
    var endCap: ArrowCap
    /// Line/arrow shaft pattern. Default `.solid` reproduces the legacy stroke.
    var dashStyle: DashStyle
    /// Arrow-only shaft profile. Default `.uniform` reproduces the legacy
    /// constant-width stroke; lines and freehand arrows ignore it.
    var shaftStyle: ShaftStyle
    /// Optional drop shadow (all shapes except blur/image). Codable default is
    /// `.off` so legacy files are unchanged; new objects get `.pronounced` via
    /// the creation-style builders.
    var shadow: ShadowStyle
    /// Text-only: horizontal alignment of the box's paragraphs.
    var textAlignment: TextAlignment
    /// Text-only: vertical placement of the text within the box rect.
    var textVerticalAlignment: TextVerticalAlignment
    /// Text-only: extra spacing (image-space points) between lines.
    var lineSpacing: CGFloat
    /// Text-only: intrinsic wrap width (image space) when it exceeds the box
    /// rect — the rect is then a MASK over text laid out at this width
    /// (manual shrink hides text instead of re-wrapping it). nil = lay out
    /// at rect.width (legacy files and never-shrunk boxes).
    var textLayoutWidth: CGFloat? = nil
    /// Contrasting outline (casing) drawn BENEATH the stroke and around the shape
    /// edge / step circle, so a mark stays legible on a busy or same-colored
    /// background. `nil` = no outline (legacy default). Applies to
    /// arrow/line/pen/rectangle/ellipse/step.
    var outlineColor: SerializableColor? = nil
    /// Outline thickness in image-space points, added on EACH side of the stroke
    /// (total casing width = strokeWidth + 2·outlineWidth). Ignored when
    /// `outlineColor` is nil.
    var outlineWidth: CGFloat = 3

    init(strokeColor: SerializableColor, strokeWidth: CGFloat,
         opacity: Double = 1.0, fillColor: SerializableColor? = nil, cornerRadius: CGFloat = 0,
         fontSize: CGFloat = 18, isBold: Bool = false,
         blurMode: BlurMode = .pixelate, blurStrength: Double = 0.5,
         startCap: ArrowCap = .none, endCap: ArrowCap = .filled,
         dashStyle: DashStyle = .solid, shaftStyle: ShaftStyle = .uniform,
         shadow: ShadowStyle = .off,
         textAlignment: TextAlignment = .left,
         textVerticalAlignment: TextVerticalAlignment = .top,
         lineSpacing: CGFloat = 0,
         outlineColor: SerializableColor? = nil, outlineWidth: CGFloat = 3) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.opacity = opacity
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
        self.isBold = isBold
        self.blurMode = blurMode
        self.blurStrength = blurStrength
        self.startCap = startCap
        self.endCap = endCap
        self.dashStyle = dashStyle
        self.shaftStyle = shaftStyle
        self.shadow = shadow
        self.textAlignment = textAlignment
        self.textVerticalAlignment = textVerticalAlignment
        self.lineSpacing = lineSpacing
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
    }

    enum CodingKeys: String, CodingKey {
        case strokeColor, strokeWidth, opacity, fillColor, cornerRadius, fontSize, isBold
        case blurMode, blurStrength
        case startCap, endCap, dashStyle, shaftStyle
        case shadow
        case textAlignment, textVerticalAlignment, lineSpacing, textLayoutWidth
        case outlineColor, outlineWidth
    }

    /// Custom decoder so older files (written before `fontSize`/`isBold`/blur and
    /// the arrow-cap/dash fields existed) decode to defaults instead of throwing.
    /// The encoder stays synthesized, so new files always include the fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokeColor = try c.decode(SerializableColor.self, forKey: .strokeColor)
        strokeWidth = try c.decode(CGFloat.self, forKey: .strokeWidth)
        opacity = try c.decode(Double.self, forKey: .opacity)
        fillColor = try c.decodeIfPresent(SerializableColor.self, forKey: .fillColor)
        cornerRadius = try c.decode(CGFloat.self, forKey: .cornerRadius)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 18
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        blurMode = try c.decodeIfPresent(BlurMode.self, forKey: .blurMode) ?? .pixelate
        blurStrength = try c.decodeIfPresent(Double.self, forKey: .blurStrength) ?? 0.5
        // Legacy-preserving defaults: an arrow with no caps stored is a single
        // filled head at the end; shafts are solid.
        startCap = try c.decodeIfPresent(ArrowCap.self, forKey: .startCap) ?? .none
        endCap = try c.decodeIfPresent(ArrowCap.self, forKey: .endCap) ?? .filled
        dashStyle = try c.decodeIfPresent(DashStyle.self, forKey: .dashStyle) ?? .solid
        shaftStyle = try c.decodeIfPresent(ShaftStyle.self, forKey: .shaftStyle) ?? .uniform
        shadow = try c.decodeIfPresent(ShadowStyle.self, forKey: .shadow) ?? .off
        textAlignment = try c.decodeIfPresent(TextAlignment.self, forKey: .textAlignment) ?? .left
        textVerticalAlignment = try c.decodeIfPresent(TextVerticalAlignment.self, forKey: .textVerticalAlignment) ?? .top
        lineSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .lineSpacing) ?? 0
        textLayoutWidth = try c.decodeIfPresent(CGFloat.self, forKey: .textLayoutWidth)
        outlineColor = try c.decodeIfPresent(SerializableColor.self, forKey: .outlineColor)
        outlineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .outlineWidth) ?? 3
    }

    /// The width text is laid out at, in image space: the wider of the box
    /// rect and the stored intrinsic layout width. The rect then clips
    /// (masks) whatever that layout produces — shrinking the rect below the
    /// intrinsic width hides text rather than re-wrapping it.
    func effectiveTextLayoutWidth(rect: CGRect) -> CGFloat {
        max(rect.width, textLayoutWidth ?? 0)
    }
}

/// Clamp a corner radius so a rounded rectangle never overlaps itself: the
/// radius can be at most half the smaller side. Negative radii clamp to 0.
func clampedCornerRadius(_ radius: CGFloat, for rect: CGRect) -> CGFloat {
    max(0, min(radius, min(abs(rect.width), abs(rect.height)) / 2))
}

/// Multiply `opacity` (0...1) into a color's alpha, in sRGB. Returns the
/// color unchanged if it can't be converted to sRGB. Shared by the live
/// canvas (EditorCanvasView) and the saved-image renderer (AnnotationRenderer).
func applyOpacity(_ color: NSColor, opacity: Double) -> NSColor {
    guard let srgb = color.usingColorSpace(.sRGB) else { return color }
    return srgb.withAlphaComponent(srgb.alphaComponent * CGFloat(opacity))
}
