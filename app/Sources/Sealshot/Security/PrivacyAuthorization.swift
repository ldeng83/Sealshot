import Foundation

/// A short-lived record that the device owner authenticated to act on the
/// Privacy & Security page. The page gate stamps it on a successful
/// `LocalAuthGate`; sensitive operations (e.g. `EncryptionToggleModel`) verify
/// it at the security boundary so they never run on view state alone.
///
/// This is the piece that lets one page-level prompt cover every sensitive
/// action on the page: the gate grants an authorization once, and each
/// operation checks it instead of re-prompting. A caller that reaches an
/// operation *without* a standing authorization (a future surface, a direct
/// call) still gets forced through a fresh owner check by the operation itself.
@MainActor
protocol PrivacyAuthorizing {
    /// True only if the owner authenticated within the validity window.
    var isAuthorized: Bool { get }
    /// Record a fresh successful owner authentication (starts the window).
    /// Operations that ran their own fallback owner check call this so their
    /// single prompt covers the page, matching the page-level unlock.
    func grant()
}

@MainActor
final class PrivacyAuthorization: PrivacyAuthorizing {
    /// App-wide instance the production page gate and models share.
    static let shared = PrivacyAuthorization()

    /// How long a single owner authentication stays valid (5 minutes). The
    /// Privacy & Security page stays unlocked for this window — across
    /// navigation and even reopening Settings — then auto-locks and re-prompts.
    /// A hard cap from the moment of `grant()`, never extended by activity.
    /// `revoke()` still force-locks immediately for any caller that needs it.
    private let validity: TimeInterval
    private let now: () -> Date
    private var authorizedUntil: Date?

    init(validity: TimeInterval = 300, now: @escaping () -> Date = Date.init) {
        self.validity = validity
        self.now = now
    }

    /// Record a fresh successful owner authentication.
    func grant() { authorizedUntil = now().addingTimeInterval(validity) }

    /// Drop any standing authorization (the page calls this when the user
    /// navigates away, so re-entering re-prompts).
    func revoke() { authorizedUntil = nil }

    var isAuthorized: Bool {
        guard let authorizedUntil else { return false }
        return now() < authorizedUntil
    }
}
