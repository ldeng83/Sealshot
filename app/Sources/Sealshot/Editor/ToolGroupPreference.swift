import Foundation

/// Persistence for the last sub-tool chosen in a toolbar `ToolGroup`
/// (Line/Arrow, Rectangle/Ellipse, …).
///
/// A grouped pill (see `GroupedToolPillView`) fronts whichever member was used
/// last; a plain click re-arms it, so we remember it across launches, keyed by
/// the group's `id`. A thin `UserDefaults` wrapper, kept single-purpose like the
/// other editor preferences. Falls back to the group's `defaultTool`.
enum ToolGroupPreference {

    private static func key(_ group: ToolGroup) -> String { "toolGroup.\(group.id).last" }

    /// The remembered member of `group`, or its `defaultTool` when nothing
    /// valid is stored.
    static func last(_ group: ToolGroup, _ defaults: UserDefaults = .standard) -> EditorTool {
        guard let raw = defaults.string(forKey: key(group)),
              let tool = EditorTool(rawValue: raw),
              group.contains(tool)
        else { return group.defaultTool }
        return tool
    }

    /// Persist the chosen member. Tools outside the group are ignored so a
    /// stray call can't corrupt the remembered value.
    static func store(_ tool: EditorTool, in group: ToolGroup, _ defaults: UserDefaults = .standard) {
        guard group.contains(tool) else { return }
        defaults.set(tool.rawValue, forKey: key(group))
    }
}
