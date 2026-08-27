import Foundation

/// Which color slot of a tool a remembered default belongs to. A tool can
/// expose several (a rectangle has a stroke AND a fill); see
/// `EditorState.colorRoles(for:)` for the per-tool set.
enum ToolColorRole: String, CaseIterable {
    case stroke        // pen/line/arrow/free-arrow stroke, shape outline, text foreground
    case fill          // rectangle/ellipse interior (nil = no fill)
    case badgeFill
    case badgeNumber
    case blurSolid
    case outline       // contrasting casing around pen/line/arrow/shape/step (nil = off)
}

/// Per-tool remembered color defaults (persisted), one slot per
/// (tool, role). Editing one tool's color never affects another; new
/// objects inherit their tool's remembered colors. Mirrors
/// `ToolShadowDefaults`.
struct ToolColorDefaults {
    private let defaults: UserDefaults
    private static let keyPrefix = "annotationColorDefault."

    /// Wrapper so an EXPLICIT nil (the shape "No fill" choice) round-trips
    /// distinctly from "never set" (key absent).
    private struct Stored: Codable { var color: SerializableColor? }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Outer nil = never set (caller should keep its built-in default);
    /// `.some(nil)` = the user explicitly chose "no color" (fill off).
    func color(_ role: ToolColorRole, for tool: EditorTool) -> SerializableColor?? {
        guard let data = defaults.data(forKey: Self.key(role, tool)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return .some(stored.color)
    }

    mutating func set(_ color: SerializableColor?, _ role: ToolColorRole, for tool: EditorTool) {
        guard let data = try? JSONEncoder().encode(Stored(color: color)) else { return }
        defaults.set(data, forKey: Self.key(role, tool))
    }

    private static func key(_ role: ToolColorRole, _ tool: EditorTool) -> String {
        keyPrefix + tool.rawValue + "." + role.rawValue
    }
}
