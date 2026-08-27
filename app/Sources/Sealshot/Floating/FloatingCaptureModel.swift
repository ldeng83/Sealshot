import Foundation

/// Everything the floating capture window DECIDES, with no AppKit in it, so the
/// promotion rule, the count's reset rule, and the launch/reopen routing are
/// unit tests rather than quit-and-relaunch cycles. `FloatingCaptureController`
/// renders these decisions; it never makes them. Mirrors how `MenuBarModel`
/// splits from `MenuBarController`.

/// One capture action the floating window can start. Every case maps to an
/// existing `CaptureCoordinator` trigger — this enum adds no new capture kinds,
/// it only names the ones the panel offers.
/// Declared in the order the overflow lists them, which is the order the
/// menu-bar menu and the Capture menu already use: the everyday capture first,
/// then the variants, then recording.
enum FloatingCaptureKind: String, CaseIterable, Equatable {
    case unified, saveAs, fullScreen, delayed, scrolling, live, record, recordSelection

    /// The action this kind maps to on the menu-bar model. Titles and icons are
    /// read from there rather than restated, so the panel, the status item and
    /// the Capture menu cannot drift apart.
    var menuAction: MenuBarAction {
        switch self {
        case .unified:         return .captureUnified
        case .saveAs:          return .captureSaveAs
        case .fullScreen:      return .captureFullscreen
        case .delayed:         return .captureDelayed
        case .scrolling:       return .captureScroll
        case .live:            return .captureLive
        case .record:          return .recordScreen
        case .recordSelection: return .recordSelection
        }
    }

    var title: String {
        switch self {
        case .unified:         return "Smart Capture"
        case .saveAs:          return "Save As Capture…"
        case .fullScreen:      return "Full Screen Capture"
        case .delayed:         return "Delayed Capture"
        case .scrolling:       return "Scrolling Capture"
        case .live:            return "Live Capture"
        case .record:          return "Record Full Screen"
        case .recordSelection: return "Record Selected Area…"
        }
    }

    /// SF Symbol for the face button and the overflow rows — the menu's own
    /// icon for the same action.
    var symbolName: String { MenuBarModel.defaultIcon(for: menuAction) }

    /// Recording actions tint red, matching the status item's record dot.
    var isRecording: Bool { self == .record || self == .recordSelection }
}

/// The panel's state. A value type: the controller holds one and re-renders
/// after every mutation.
struct FloatingCaptureModel: Equatable {
    /// The kind on the single face button — whatever was used last. The face is
    /// a shortcut to the previous choice, not a fixed slot, which is why every
    /// kind (including this one) stays listed in the overflow.
    private(set) var faceKind: FloatingCaptureKind = .unified

    /// Captures since the editor was last opened. Bounded by construction: it
    /// resets the moment the user goes and looks, so it can never drift into a
    /// meaningless lifetime total and needs no manual clear.
    private(set) var count: Int = 0

    /// Record that a kind was chosen: it becomes the face button.
    mutating func perform(_ kind: FloatingCaptureKind) {
        faceKind = kind
    }

    /// A capture actually completed. Separate from `perform` because a
    /// cancelled selection must not inflate the tally.
    mutating func captureLanded() {
        count += 1
    }

    /// The editor became visible by ANY route — the ⤢ button, ⌘⇧E, the Dock,
    /// the menu bar. The count has served its purpose, so it starts over.
    mutating func editorWasOpened() {
        count = 0
    }
}

/// Launch policy, kept pure so it is a test rather than a hand-run of
/// quit-and-relaunch.
///
/// Dock-icon clicks are deliberately NOT routed here: a Dock click always opens
/// the editor, whether or not the panel is showing. The panel is a companion to
/// the editor, never a substitute for it.
enum FloatingCaptureLifecycle {
    /// No setting: the app simply comes back the way it was left. For the user
    /// this is aimed at, the floating panel is not something they summon — it
    /// is what Sealshot looks like.
    static func shouldRestoreAtLaunch(wasOpenAtQuit: Bool) -> Bool { wasOpenAtQuit }
}

/// Whether the panel floats above every window, or rides the editor.
enum FloatingPinState: String, Equatable {
    case pinned, unpinned

    var isPinned: Bool { self == .pinned }
    var toggled: FloatingPinState { self == .pinned ? .unpinned : .pinned }

    /// The state has to be readable from the glyph alone — the button carries
    /// no label, and the panel is too small for one.
    var symbolName: String { self == .pinned ? "pin.fill" : "pin.slash" }

    var tooltip: String {
        switch self {
        case .pinned:   return "Unpin — let other windows cover this"
        case .unpinned: return "Pin on top of other windows"
        }
    }
}

/// Kept pure so the rule is a test rather than a hand-run of drag-behind-a-window.
enum FloatingPinPolicy {
    /// Pinned: what the panel shipped with, and what an always-on-top capture
    /// panel is for.
    static let defaultState: FloatingPinState = .pinned

    /// Whether the panel must be re-ordered above the editor when the editor
    /// comes forward. Only unpinned — a pinned panel is above it already.
    static func followsEditor(_ state: FloatingPinState) -> Bool { !state.isPinned }

    /// Whether ordering the panel above the editor can actually do anything
    /// right now. Window levels are ABSOLUTE: a `.normal` panel ordered above a
    /// `.floating` editor does not move, the call is silently dropped, and the
    /// editor stays on top. This is exactly what happens during the editor's
    /// 0.25s `.floating` promotion, which is when `didBecomeKey` fires — so the
    /// panel must also be re-ordered once that promotion is undone.
    ///
    /// Raw level values rather than `NSWindow.Level`, so the rule stays in this
    /// AppKit-free file with the rest of the panel's decisions.
    static func orderAboveTakesEffect(panelLevel: Int, editorLevel: Int) -> Bool {
        editorLevel <= panelLevel
    }
}

/// Remembered across launches, beside the panel's position and open-at-quit.
struct FloatingPinPreference {
    private static let key = "FloatingCaptureWindowPinned"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Absent reads as the default rather than as `false`, so an existing
    /// install comes back pinned rather than silently dropping behind windows.
    var state: FloatingPinState {
        get {
            guard defaults.object(forKey: Self.key) != nil else {
                return FloatingPinPolicy.defaultState
            }
            return defaults.bool(forKey: Self.key) ? .pinned : .unpinned
        }
        nonmutating set { defaults.set(newValue.isPinned, forKey: Self.key) }
    }
}

/// Whether the panel tucks itself against the nearest edge as soon as the
/// pointer leaves it.
///
/// Off by default: auto-hiding is a strong behaviour to inflict on someone who
/// never asked for it, and the panel is deliberately small enough to leave out.
struct FloatingAutoDockPreference {
    private static let key = "FloatingCaptureWindowAutoDock"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
