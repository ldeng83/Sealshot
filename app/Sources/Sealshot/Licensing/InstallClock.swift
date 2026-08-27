import Foundation
import Security

/// The raw values are ON DISK — UserDefaults keys ("license.trialStart"),
/// filenames (".lic-trialStart") and keychain accounts — in every install
/// since the trial era. Renaming them would read as a fresh install to every
/// existing user and reset the age the support reminder waits on, so they stay
/// exactly as they are however the Swift names read.
enum InstallStampKey: String {
    case installedAt = "trialStart"
    case lastSeen = "lastSeen"
}

/// One hiding place for the install timestamp. Stored redundantly (defaults +
/// file + keychain); the EARLIEST stamp wins and is healed everywhere, so
/// wiping any single store never makes the install look newer than it is.
protocol InstallStampStore {
    func read(key: InstallStampKey) -> Date?
    func write(_ date: Date, key: InstallStampKey)
}

final class InMemoryStampStore: InstallStampStore {
    private var values: [InstallStampKey: Date] = [:]
    func read(key: InstallStampKey) -> Date? { values[key] }
    func write(_ date: Date, key: InstallStampKey) { values[key] = date }
    func wipe() { values = [:] }
    /// Lose ONE key — the shape of a partially-cleared store, which is what
    /// healing has to survive.
    func forget(_ key: InstallStampKey) { values[key] = nil }
}

final class DefaultsStampStore: InstallStampStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func name(_ key: InstallStampKey) -> String { "license." + key.rawValue }
    func read(key: InstallStampKey) -> Date? {
        let t = defaults.double(forKey: name(key))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func write(_ date: Date, key: InstallStampKey) {
        defaults.set(date.timeIntervalSince1970, forKey: name(key))
    }
}

final class FileStampStore: InstallStampStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    private func url(_ key: InstallStampKey) -> URL {
        directory.appendingPathComponent(".lic-" + key.rawValue)
    }
    func read(key: InstallStampKey) -> Date? {
        guard let s = try? String(contentsOf: url(key), encoding: .utf8),
              let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    func write(_ date: Date, key: InstallStampKey) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? String(date.timeIntervalSince1970).write(to: url(key), atomically: true, encoding: .utf8)
    }
}

/// Same shape as KeychainIdentityStore: plain generic password, no
/// SecAccessControl (avoids errSecMissingEntitlement on locally-signed builds).
final class KeychainStampStore: InstallStampStore {
    private let service = "com.seal-shot.sealshot.license"
    func read(key: InstallStampKey) -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8),
              let t = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    func write(_ date: Date, key: InstallStampKey) {
        let data = Data(String(date.timeIntervalSince1970).utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        var add = base
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }
}

/// How long this copy of Sealshot has been on this Mac.
///
/// This was the trial clock. There is no trial — nothing expires and nothing
/// counts down — but the install date survived the model change because the
/// support reminder waits on it (`SupportNudgePolicy.earliestDays`), and it has
/// to be a date a defaults wipe can't quietly reset to "today".
struct InstallClock {
    let stores: [any InstallStampStore]

    init(stores: [any InstallStampStore]) {
        self.stores = stores
    }

    static func production() -> InstallClock {
        let appSupport = AppSupportDirectory.sealshot
        return InstallClock(stores: [DefaultsStampStore(),
                                   FileStampStore(directory: appSupport),
                                   KeychainStampStore()])
    }

    /// The earliest recorded start, read without writing anything — the same
    /// value `heal` would write into every store. Callers that only want to
    /// know how long this install has been around (the support reminder) have no
    /// business stamping `lastSeen` as a side effect of asking.
    var recordedStart: Date? {
        stores.compactMap { $0.read(key: .installedAt) }.min()
    }

    /// Seed the install stamp on first run, and heal it back into any store it
    /// has been wiped from. Returns the effective install date.
    ///
    /// Something must call this at launch or the redundancy is decorative: a
    /// user who clears defaults would be re-seeded with today's date only on
    /// the next launch that happens to run it. `EntitlementStore.evaluate()` is
    /// that caller, and it does so for EVERY state — a licensed user who later
    /// lapses must not get an install date of "the day the license lapsed".
    @discardableResult
    func heal(now: Date = Date()) -> Date {
        // Rollback clamp: the observed date never moves backwards, so setting
        // the system clock back can't make an old install look new.
        let lastSeen = stores.compactMap { $0.read(key: .lastSeen) }.max()
        let effectiveNow = max(now, lastSeen ?? .distantPast)
        for s in stores { s.write(effectiveNow, key: .lastSeen) }

        // Earliest recorded start wins; heal it into every store.
        let start = stores.compactMap { $0.read(key: .installedAt) }.min() ?? effectiveNow
        for s in stores { s.write(start, key: .installedAt) }
        return start
    }
}
