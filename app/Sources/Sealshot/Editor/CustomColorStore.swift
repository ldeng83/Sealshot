import AppKit

/// The user's saved "My colors", persisted as hex strings in `UserDefaults`,
/// newest-first, de-duplicated by hex, capped at `maxColors`. Shared across all
/// color chips so a color saved in one place is available everywhere.
final class CustomColorStore {
    static let shared = CustomColorStore()
    static let maxColors = 12

    private let defaults: UserDefaults
    private let key = "editor.customColors"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var hexes: [String] {
        get { (defaults.array(forKey: key) as? [String]) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    var colors: [NSColor] {
        hexes.compactMap { color(fromHex: $0) }
    }

    func add(_ color: NSColor) {
        let hex = hexString(from: color)
        var list = hexes.filter { $0 != hex }     // de-dup
        list.insert(hex, at: 0)                    // newest first
        if list.count > Self.maxColors { list = Array(list.prefix(Self.maxColors)) }
        hexes = list
    }

    func remove(_ color: NSColor) {
        let hex = hexString(from: color)
        hexes = hexes.filter { $0 != hex }
    }
}
