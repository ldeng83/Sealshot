import Foundation

/// What the editor's right sidebar is currently showing. Info and Find in Image
/// behave like peers of the drawing tools: only one long-lived mode owns the
/// toolbar highlight and sidebar at a time. Pure value type — the transition
/// rules live here so they can be unit-tested without any AppKit.
enum SidebarPanelMode: String {
    /// Contextual tool/selection/object properties (the existing sidebar).
    case properties
    /// File information (Name, dimensions, dates, source app, size, tags).
    case info
    /// OCR-backed keyword search controls and canvas result highlights.
    case imageTextSearch

    var isInfo: Bool { self == .info }
    var isImageTextSearch: Bool { self == .imageTextSearch }

    /// 'i' pill toggle: flip between Info and Properties.
    func toggledInfo() -> SidebarPanelMode { self == .info ? .properties : .info }

    /// A tool was selected. Sidebar-owning modes are peers of the tools, so
    /// picking ANY tool exits them back to Properties.
    func afterToolSelected() -> SidebarPanelMode {
        .properties
    }

    /// Whether file Info is actually DISPLAYED right now. Info mode being on is
    /// necessary but not sufficient: a current selection or an in-progress
    /// redaction review shows that content instead, so the 'i' pill highlights
    /// only when Info is the thing on screen.
    func showsInfo(selectionCount: Int, reviewingRedactions: Bool) -> Bool {
        self == .info && selectionCount == 0 && !reviewingRedactions
    }
}
