import Foundation

/// Which tool is currently active. Set by toolbar clicks; read by
/// `EditorCanvasView` to interpret mouse drags. `.select` is the neutral
/// default tool: it selects / moves / marquees existing objects. Drawing tools
/// are explicit opt-in. (Image info lives in the right sidebar, not a tool —
/// see `EditorState.showsInfoPanel` / `EditorSidebarView`.)
enum EditorTool: String, CaseIterable {
    case select
    /// Pan tool: drags the image (repositions the focus over the image when one
    /// is set, else scrolls the view). Non-drawing, like `.select`.
    case hand
    case textSelect
    case crop
    case pen
    case arrow
    /// Free-draw arrow: freehand stroke (like `.pen`) with arrowhead caps
    /// (like `.arrow`). Grouped behind the Arrow pill's chevron.
    case penArrow
    case rectangle
    case text
    case ellipse
    case line
    case badge
    case blur
}
