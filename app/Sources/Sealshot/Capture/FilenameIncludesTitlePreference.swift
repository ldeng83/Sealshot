import Foundation

/// Whether a capture's filename includes the generated title + source app
/// ("App Title date") or is a bare timestamp. Governs ALL captures — turning
/// it off keeps filenames content-free even without Enhanced Security.
///
/// Default ON (the historic plaintext naming). Enabling Enhanced Security
/// applies a privacy default of OFF via `applyEncryptionPrivacyDefault` —
/// unless the user chose explicitly — so encrypted libraries keep
/// timestamp-only names out of the box (the title still lives inside the
/// encrypted manifest and shows as the display name).
struct FilenameIncludesTitlePreference {
    private static let key = "FilenameIncludesTitle"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var enabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    /// Back to "never chosen": the plain default (ON). Callers resetting the
    /// Capture tab re-apply the encryption privacy default afterwards.
    func resetToDefault() { defaults.removeObject(forKey: Self.key) }

    /// Idempotent privacy default: when Enhanced Security is enabled and the
    /// user never touched the toggle, record OFF explicitly. Called at launch
    /// (migrates pre-unification encrypted libraries, whose captures were
    /// already timestamp-only) and when encryption is enabled. An explicit
    /// prior choice — either way — is never overridden.
    static func applyEncryptionPrivacyDefault(encryptionEnabled: Bool,
                                              defaults: UserDefaults = .standard) {
        guard encryptionEnabled, defaults.object(forKey: key) == nil else { return }
        defaults.set(false, forKey: key)
    }
}
