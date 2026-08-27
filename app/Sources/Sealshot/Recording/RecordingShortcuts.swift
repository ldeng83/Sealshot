import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Starts a recording; while recording, toggles stop.
    static let recordToggle = Self("recordToggle", default: .init(.v, modifiers: [.command, .shift]))
    /// Records a region/window chosen via the capture overlay.
    static let recordSelection = Self("recordSelection", default: .init(.r, modifiers: [.command, .shift]))
    /// Pauses/resumes the running recording. Keyboard-only on purpose: reaching
    /// for the HUD with the mouse puts the pause gesture into the recording
    /// itself. No-op while not recording.
    static let recordPause = Self("recordPause", default: .init(.p, modifiers: [.command, .shift]))
}
