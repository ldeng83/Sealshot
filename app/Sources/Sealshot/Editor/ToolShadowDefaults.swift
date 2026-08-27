import Foundation

/// Per-tool remembered shadow defaults, persisted in UserDefaults. Each of the
/// seven drawing tools keeps its own `ShadowStyle`; editing one never affects
/// another. Unset tools report `.pronounced` (the ship default).
struct ToolShadowDefaults {
    private let defaults: UserDefaults
    private static let keyPrefix = "annotationShadowDefault."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func shadow(for tool: EditorTool) -> ShadowStyle {
        guard let data = defaults.data(forKey: Self.keyPrefix + tool.rawValue),
              let s = try? JSONDecoder().decode(ShadowStyle.self, from: data)
        else { return .pronounced }
        return s
    }

    mutating func set(_ shadow: ShadowStyle, for tool: EditorTool) {
        guard let data = try? JSONEncoder().encode(shadow) else { return }
        defaults.set(data, forKey: Self.keyPrefix + tool.rawValue)
    }
}
