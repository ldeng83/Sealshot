import Foundation

/// Decides whether the editor window should be hidden during a drag.
///
/// Deliberately free of AppKit windows and timers so every rule is a unit test
/// rather than a manual drag. The controller owns the I/O; this owns the rules.
///
/// Two guards, both learned the hard way by `FloatingCaptureController`:
/// restore only what WE hid, and never touch a window that was not visible when
/// the drag began (otherwise a drag started with the editor closed would summon
/// it on drop).
struct DragPeekState: Equatable {

    enum Action: Equatable { case none, hide, restore }

    private(set) var isHidden = false
    private var isActive = false
    private var wasVisibleAtStart = false

    init() {}

    mutating func begin(windowWasVisible: Bool) {
        isActive = true
        wasVisibleAtStart = windowWasVisible
        isHidden = false
    }

    /// One 50ms tick. `anyMouseButtonDown` is the watchdog: a drag holds the
    /// button for its entire life, so the button coming up while we still think
    /// a drag is running means `endedAt` never reached us.
    mutating func update(modifierHeld: Bool, anyMouseButtonDown: Bool) -> Action {
        guard isActive else { return .none }

        if !anyMouseButtonDown {
            isActive = false
            guard isHidden else { return .none }
            isHidden = false
            return .restore
        }

        guard wasVisibleAtStart else { return .none }

        if modifierHeld, !isHidden {
            isHidden = true
            return .hide
        }
        if !modifierHeld, isHidden {
            isHidden = false
            return .restore
        }
        return .none          // steady state — do NOT re-issue every tick
    }

    mutating func end() -> Action {
        isActive = false
        guard isHidden else { return .none }
        isHidden = false
        return .restore
    }

    /// Force the window visible without ending the session — the app-activation
    /// failsafe. `isActive` is deliberately untouched so a later ⌃ press in the
    /// same drag can hide it again.
    mutating func forceVisible() -> Action {
        guard isHidden else { return .none }
        isHidden = false
        return .restore
    }
}
