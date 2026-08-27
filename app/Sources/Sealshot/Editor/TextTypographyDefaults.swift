import AppKit

/// Persisted typographic defaults for the Text tool — the settings a new text
/// box inherits, remembered across launches. Color and opacity are deliberately
/// NOT here: those are per-tool creation defaults owned by `ToolColorDefaults` /
/// `ToolOpacityDefaults`. This blob covers only the text-specific typography no
/// other tool exposes, so the Text tool reopens with the last-used look.
struct TextTypographyDefaults: Codable, Equatable {
    var fontFamily: String?
    var fontSize: CGFloat
    var isBold: Bool
    var weight: TextWeight?
    var isItalic: Bool
    var underline: Bool
    var strikethrough: Bool
    var highlight: SerializableColor?
    var outlineColor: SerializableColor?
    var outlineWidth: CGFloat
    var alignment: TextAlignment
    var verticalAlignment: TextVerticalAlignment
    var lineSpacing: CGFloat

    /// First-launch defaults — must match the historical hardcoded seeds so
    /// behavior is unchanged until the user styles their first text box. Font
    /// family follows the legacy "last font remembered" key for continuity.
    static let fallback = TextTypographyDefaults(
        fontFamily: AnnotationTextFont.remembered, fontSize: 18, isBold: false,
        weight: nil, isItalic: false, underline: false, strikethrough: false,
        highlight: nil, outlineColor: nil, outlineWidth: 6,
        alignment: .left, verticalAlignment: .top, lineSpacing: 0)
}

/// UserDefaults-backed persistence for `TextTypographyDefaults`, mirroring the
/// thin-wrapper style of `AnnotationTextFont.remembered`. A decode failure falls
/// back to `.fallback` so a schema change never wedges the editor.
enum TextTypographyDefaultsStore {
    private static let key = "textTypographyDefaults.v1"

    static var current: TextTypographyDefaults {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let value = try? JSONDecoder().decode(TextTypographyDefaults.self, from: data)
            else { return .fallback }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
