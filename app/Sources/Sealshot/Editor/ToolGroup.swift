import Foundation

/// A set of related drawing tools collapsed behind a single
/// `GroupedToolPillView` in the editor toolbar (e.g. Line/Arrow, or
/// Rectangle/Ellipse). The grouped pill fronts the last-used member; a chooser
/// popover switches between members. Pure value type — no UI, no actor
/// isolation — so it's shared by the toolbar builder, the preference store, and
/// tests alike.
struct ToolGroup {

    /// One member tool plus the SF Symbol + label used to front it.
    struct Member {
        let tool: EditorTool
        let symbol: String
        let label: String
    }

    /// Stable identifier, also used as the `UserDefaults` key suffix for the
    /// remembered sub-tool. Must be unique across groups.
    let id: String
    /// Members in the order shown in the chooser popover.
    let members: [Member]
    /// The member armed when nothing has been remembered yet.
    let defaultTool: EditorTool

    var tools: [EditorTool] { members.map(\.tool) }

    func contains(_ tool: EditorTool) -> Bool {
        members.contains { $0.tool == tool }
    }

    func member(_ tool: EditorTool) -> Member? {
        members.first { $0.tool == tool }
    }
}
