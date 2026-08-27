import AppKit

/// The area of the last region capture, so it can be captured again without
/// reselecting it.
///
/// Remembered PER DISPLAY, and re-validated every time it is used. A stored
/// rectangle is a promise about pixels the user cannot see when they press the
/// shortcut, and screens move: unplug a monitor, rearrange displays, or change
/// resolution and yesterday's coordinates point at something else entirely —
/// or at nothing. The rule this type exists to enforce is that a region is
/// either still exactly where it was, or it is refused. It is never clamped,
/// shifted, or best-guessed onto another screen: silently capturing the wrong
/// pixels is worse than asking the user to drag a new box, because they may
/// not notice, and by then the screenshot is in a document.
struct LastCaptureRegionStore {
    private static let key = "LastCaptureRegion"

    /// A remembered area: the rect in global AppKit points, plus the identity
    /// of the display it was drawn on. Both halves are needed — a rect alone
    /// cannot say WHICH screen it belonged to once the arrangement changes.
    struct StoredRegion: Equatable {
        var rect: CGRect
        var displayID: String
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var stored: StoredRegion? {
        guard let raw = defaults.string(forKey: Self.key) else { return nil }
        return StoredRegion(sealshotString: raw)
    }

    func record(_ region: StoredRegion) {
        defaults.set(region.sealshotString, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// The remembered area as something capturable, or nil when it can no
    /// longer be honoured exactly.
    ///
    /// Deliberately strict — `contains`, not `intersects`. A region hanging
    /// half off its screen would capture a band of desktop where the user
    /// expects content, and unlike a panel position (which only has to be
    /// reachable) a capture rect has to be RIGHT.
    static func resolve(_ region: StoredRegion?, screens: [NSScreen],
                        displayID: (NSScreen) -> String?) -> SelectedRegion? {
        guard let region else { return nil }
        guard let screen = screens.first(where: { displayID($0) == region.displayID })
        else { return nil }
        guard screen.frame.contains(region.rect) else { return nil }
        return SelectedRegion(globalRect: region.rect, screen: screen)
    }
}

extension LastCaptureRegionStore.StoredRegion {
    /// Plain-string encoding, matching `FloatingCapturePositionStore`: a
    /// malformed value decodes to nil rather than to a zero rect, which would
    /// be indistinguishable from a real one.
    var sealshotString: String {
        ["\(rect.origin.x)", "\(rect.origin.y)", "\(rect.size.width)", "\(rect.size.height)",
         displayID].joined(separator: " ")
    }

    init?(sealshotString: String) {
        let parts = sealshotString.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return nil }
        let numbers = parts.prefix(4).compactMap(Double.init)
        guard numbers.count == 4, !parts[4].isEmpty else { return nil }
        guard numbers[2] > 0, numbers[3] > 0 else { return nil }
        self.init(rect: CGRect(x: numbers[0], y: numbers[1],
                               width: numbers[2], height: numbers[3]),
                  displayID: parts[4])
    }
}
