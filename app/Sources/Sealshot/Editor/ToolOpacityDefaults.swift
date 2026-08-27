import Foundation

/// Per-tool remembered creation-opacity defaults (persisted), one slot per
/// tool. Editing one tool's opacity never affects another; new objects inherit
/// their tool's remembered opacity. Mirrors `ToolColorDefaults` /
/// `ToolShadowDefaults`. Opacity is a single scalar per tool (unlike color's
/// several roles), so there is no role dimension and no "explicit nil" case —
/// a missing key simply means "never set, keep the built-in default".
struct ToolOpacityDefaults {
    private let defaults: UserDefaults
    private static let keyPrefix = "annotationOpacityDefault."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// nil = never set (caller should keep its built-in default).
    func opacity(for tool: EditorTool) -> Double? {
        let key = Self.key(tool)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    mutating func set(_ opacity: Double, for tool: EditorTool) {
        defaults.set(opacity, forKey: Self.key(tool))
    }

    private static func key(_ tool: EditorTool) -> String {
        keyPrefix + tool.rawValue
    }
}
