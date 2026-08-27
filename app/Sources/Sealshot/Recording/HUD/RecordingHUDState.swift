import Foundation

/// Pure state for the floating recording HUD (the draggable dot). Drives what
/// `RecordingHUDView` renders; kept free of AppKit so it can be unit-tested.
///
/// Collapsed shows `● 0:23` (red, amber when paused). It expands to reveal
/// Pause/Stop when hovered (temporary) or pinned (sticky via click). The view
/// maps `isExpanded` / `isAmber` / `timeText` onto pixels.
struct RecordingHUDState: Equatable {
    var elapsedSeconds: Int = 0
    var isPaused: Bool = false
    private var hovering: Bool = false
    private var pinned: Bool = false
    private var grace: Bool = false

    /// Expanded while hovered OR pinned (a pin survives the pointer leaving)
    /// OR during the start-of-recording grace window, which shows Pause/Stop
    /// up front so the just-appeared HUD is easy to spot.
    var isExpanded: Bool { hovering || pinned || grace }

    /// Amber while paused, red while actively recording.
    var isAmber: Bool { isPaused }

    var timeText: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    mutating func setHovering(_ inside: Bool) { hovering = inside }

    /// The controller opens the grace window when recording starts and closes
    /// it a few seconds later; hover/pin behavior is unaffected.
    mutating func setGraceExpanded(_ on: Bool) { grace = on }

    /// Click on the dot toggles the sticky (pinned-open) state.
    mutating func togglePin() { pinned.toggle() }
}
