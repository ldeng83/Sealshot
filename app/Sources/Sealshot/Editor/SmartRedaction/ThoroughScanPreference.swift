import Foundation

/// User opt-in for the Foundation-Model "Thorough scan" backstop. Default off.
struct ThoroughScanPreference {
    private let key = "RedactionThoroughScan"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var enabled: Bool {
        get { defaults.bool(forKey: key) }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }
}

/// Whether the FM open-vocabulary backstop should run this scan. Pure; the
/// caller supplies the live values (and pairs it with an `#available(macOS 26)`
/// check at the call site).
enum RedactionBackstopGate {
    static func shouldRun(thorough: Bool, aiEnabled: Bool, fmAvailable: Bool) -> Bool {
        thorough && aiEnabled && fmAvailable
    }
}
