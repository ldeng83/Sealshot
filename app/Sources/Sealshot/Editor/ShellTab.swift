import Foundation

/// The top-level tabs of the main window shell. (Recordings were folded into the
/// Library tab as a Videos filter — see `LibrarySection`.)
enum ShellTab: Int, CaseIterable {
    case editor
    case library
    case settings

    var title: String {
        switch self {
        case .editor: return "Editor"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    /// The editor's NSToolbar (undo/redo/capture/tools/export) is only
    /// meaningful on the Editor tab.
    var showsEditorToolbar: Bool { self == .editor }

    init?(segmentIndex: Int) {
        guard let tab = ShellTab(rawValue: segmentIndex) else { return nil }
        self = tab
    }

    /// Whether this tab's content view must be hidden, given the selected tab
    /// and the encryption lock.
    ///
    /// Extracted from `EditorWindowController.selectTab` so the rule that
    /// matters — **while locked, no tab renders** — is pinned by a test rather
    /// than living only in view code. It previously applied to the editor
    /// column alone, leaving Library and Settings protected only by the lock
    /// overlay covering them; that is a weaker guarantee, and it failed when a
    /// tab visited for the first time while locked was added above the overlay.
    static func isContentHidden(_ tab: ShellTab, selected: ShellTab, locked: Bool) -> Bool {
        locked || tab != selected
    }

    /// Where the shell starts with nothing remembered — a fresh launch.
    static let launchTab: ShellTab = .editor

    /// What a Dock-icon click should do, given whether the editor window is
    /// still open and which tab it last showed.
    ///
    /// Kept pure so the rule is pinned by a test rather than needing a hand-run
    /// of quit / close / click-the-Dock.
    enum DockReopenAction: Equatable {
        /// The window is already open: raise it and change nothing else. A Dock
        /// click means "show me the app", not "take me to the Editor" — it must
        /// not throw away the tab the user was on.
        case raiseExisting
        /// No window: open one, back on the tab it was showing when it closed.
        case openRestoringTab(ShellTab)
    }

    /// `hasEditorWindow` is deliberately the EDITOR window, not AppKit's
    /// `hasVisibleWindows`: the floating capture panel is a window too, and
    /// keying off that made a Dock click do nothing whenever the panel showed.
    static func dockReopenAction(hasEditorWindow: Bool,
                                 lastSelectedTab: ShellTab) -> DockReopenAction {
        hasEditorWindow ? .raiseExisting : .openRestoringTab(lastSelectedTab)
    }
}
