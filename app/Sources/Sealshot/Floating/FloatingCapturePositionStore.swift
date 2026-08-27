import Foundation

/// Where the floating panel sits, remembered PER DISPLAY.
///
/// `NSWindow.setFrameAutosaveName` would be one line, and is what
/// `ExtractionResultWindowController` uses — but it stores a single frame with
/// no display identity. Dock a laptop, drag the panel onto the external
/// monitor, undock, and that one remembered frame restores the panel onto
/// coordinates no attached screen covers. Keying by display, plus the
/// `validated` check on restore, makes that unreachable.
struct FloatingCapturePositionStore {
    private static let key = "FloatingCaptureWindowFrames"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The remembered frame for a display, or nil if we've never seen it.
    func frame(forDisplay id: String) -> CGRect? {
        guard let stored = defaults.dictionary(forKey: Self.key)?[id] as? String,
              let rect = CGRect(sealshotString: stored) else { return nil }
        return rect
    }

    mutating func setFrame(_ frame: CGRect, forDisplay id: String) {
        var frames = defaults.dictionary(forKey: Self.key) ?? [:]
        frames[id] = frame.sealshotString
        defaults.set(frames, forKey: Self.key)
    }

    /// Keep a remembered frame only if it still lands on an attached screen.
    /// `intersects` (not `contains`) so a panel hanging slightly off an edge is
    /// still recoverable rather than thrown away.
    static func validated(_ frame: CGRect?, against visibleFrames: [CGRect]) -> CGRect? {
        guard let frame else { return nil }
        return visibleFrames.contains(where: { $0.intersects(frame) }) ? frame : nil
    }

    // MARK: Docked state

    /// A panel tucked against a screen edge. Remembered separately from the
    /// free-floating frame — and alongside the size it had BEFORE docking,
    /// which is what a click on the line restores it to. Without the size a
    /// restored dock would reopen at the line's own 18pt dimensions.
    struct DockedState: Equatable {
        var edge: FloatingCaptureGeometry.DockEdge
        var line: CGRect
        var panelSize: CGSize
    }

    private static let dockKey = "FloatingCaptureWindowDock"

    func dockState(forDisplay id: String) -> DockedState? {
        guard let stored = defaults.dictionary(forKey: Self.dockKey)?[id] as? String else { return nil }
        return DockedState(sealshotString: stored)
    }

    mutating func setDockState(_ state: DockedState, forDisplay id: String) {
        var all = defaults.dictionary(forKey: Self.dockKey) ?? [:]
        all[id] = state.sealshotString
        defaults.set(all, forKey: Self.dockKey)
    }

    mutating func clearDockState(forDisplay id: String) {
        guard var all = defaults.dictionary(forKey: Self.dockKey) else { return }
        all[id] = nil
        defaults.set(all, forKey: Self.dockKey)
    }

    /// Forget every display's dock. For "Reset Position", whose whole job is to
    /// undo a state the user cannot otherwise get out of — including a dock
    /// remembered for a display they are not currently looking at.
    mutating func clearAllDockStates() {
        defaults.removeObject(forKey: Self.dockKey)
    }
}

extension FloatingCapturePositionStore.DockedState {
    /// Same plain-string encoding as the frames above, for the same reason.
    var sealshotString: String {
        [edge.rawValue,
         "\(line.origin.x)", "\(line.origin.y)", "\(line.size.width)", "\(line.size.height)",
         "\(panelSize.width)", "\(panelSize.height)"].joined(separator: " ")
    }

    init?(sealshotString: String) {
        let parts = sealshotString.split(separator: " ").map(String.init)
        guard parts.count == 7,
              let edge = FloatingCaptureGeometry.DockEdge(rawValue: parts[0]) else { return nil }
        let numbers = parts.dropFirst().compactMap(Double.init)
        guard numbers.count == 6 else { return nil }
        self.init(edge: edge,
                  line: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                  panelSize: CGSize(width: numbers[4], height: numbers[5]))
    }
}

/// Plain-string encoding for `CGRect`, so the store stays AppKit-free and its
/// tests need no window server. `NSStringFromRect` would drag in AppKit and
/// silently returns `.zero` for malformed input, which is indistinguishable
/// from a legitimately-zero frame.
private extension CGRect {
    var sealshotString: String { "\(origin.x) \(origin.y) \(size.width) \(size.height)" }

    init?(sealshotString: String) {
        let parts = sealshotString.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        self.init(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
