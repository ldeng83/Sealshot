import Foundation

/// When — and how rarely — to ask an unlicensed user to buy Sealshot.
///
/// Sealshot is free to use. Every feature works, nothing expires, and no capture
/// is ever refused. What a license buys is that this ask stops, and that the
/// developer gets paid; the model is Shottr's and Sublime Text's, where the app
/// is whole and the reminder is the only thing you are removing.
///
/// The policy lives apart from the presenting code and takes its inputs as
/// values, because "when does the nag appear" is precisely the kind of rule that
/// is miserable to verify by running the app for thirty days. Everything below is
/// a pure function of (age, work done, last ask).
enum SupportNudgePolicy {
    /// Not before this much time. Shottr waits 30 days; the principle is that an
    /// app should earn the ask before making it.
    static let earliestDays = 30
    /// …or this much use, whichever comes first. Someone who takes 100 captures
    /// in a fortnight has had the value; waiting out the calendar would be
    /// pedantry.
    static let earliestCaptures = 100
    /// Minimum gap between asks. Two weeks is often enough to be noticed and
    /// rare enough not to be resented.
    static let cadenceDays = 14

    struct Inputs {
        /// First run, from the install stamp (`InstallClock`) — which survives
        /// a defaults wipe and so cannot be reset by accident.
        var firstRunAt: Date?
        var captureCount: Int
        var lastAskedAt: Date?
        /// A valid, unrevoked license covering the running build.
        var isSupported: Bool
        var now: Date
    }

    static func isDue(_ i: Inputs) -> Bool {
        // Paid: never ask again. This is the entire product of the transaction,
        // so it has to be absolute.
        if i.isSupported { return false }

        let days = i.firstRunAt.map { Int(i.now.timeIntervalSince($0) / 86_400) } ?? 0
        guard days >= earliestDays || i.captureCount >= earliestCaptures else { return false }

        if let last = i.lastAskedAt {
            let sinceLast = Int(i.now.timeIntervalSince(last) / 86_400)
            // A clock that moved backwards must not unlock an early ask.
            guard sinceLast >= cadenceDays else { return false }
        }
        return true
    }
}

/// The counters the policy reads. Plain defaults on purpose: unlike the install
/// stamp, nothing here is worth hiding in three places — a user who
/// clears it gets asked once more, which is not a loss worth engineering against.
@MainActor
final class SupportNudgeStore {
    static let shared = SupportNudgeStore()

    private let defaults: UserDefaults
    private static let countKey = "support.captureCount"
    private static let lastAskedKey = "support.lastAskedAt"
    private static let acknowledgedKey = "support.acknowledgedAt"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var captureCount: Int { defaults.integer(forKey: Self.countKey) }

    var lastAskedAt: Date? {
        let t = defaults.double(forKey: Self.lastAskedKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Called when a capture or recording actually lands — not when one is
    /// started, so an abandoned selection does not count towards the ask.
    func recordCreation() {
        defaults.set(captureCount + 1, forKey: Self.countKey)
    }

    /// The honor system's whole mechanism: "I've donated" sets this, and the
    /// reminder never returns. Nothing verifies it — the app is open to anyone,
    /// so a check would be theater, and a donation model that second-guesses
    /// its donors has misunderstood itself. A defaults wipe clears it; ticking
    /// the box again is the entire recovery procedure.
    var acknowledgedAt: Date? {
        let t = defaults.double(forKey: Self.acknowledgedKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var isAcknowledged: Bool { acknowledgedAt != nil }

    func acknowledge(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.acknowledgedKey)
    }

    /// Unticking the box in Settings — mostly for someone who ticked it by
    /// accident and would rather keep being asked.
    func withdrawAcknowledgement() {
        defaults.removeObject(forKey: Self.acknowledgedKey)
    }

    func recordAsked(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastAskedKey)
    }
}
