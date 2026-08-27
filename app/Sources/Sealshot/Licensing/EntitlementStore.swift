import Foundation

/// What `activate` did — or refused to do. The comparison exists so that
/// re-opening an old email attachment can never shorten a paid-for update
/// window, which the plain overwrite it replaces did silently.
enum ActivationOutcome: Equatable {
    case installed(LicensePayload)
    case alreadyInstalled
    case olderRejected(current: LicensePayload, offered: LicensePayload)
    case needsConfirmation(current: LicensePayload, offered: LicensePayload)
}

/// The one licensing question the rest of the app asks. ObservableObject (not
/// @Observable) to match AppLockState — it's consumed the same way from the
/// SwiftUI menu closures and from AppKit controllers.
@MainActor
final class EntitlementStore: ObservableObject {
    enum State: Equatable {
        case licensed(LicensePayload)
        /// License file is VALID, but this build was released after the
        /// license's updatesThrough window (someone installed a newer DMG
        /// manually — Sparkle can't offer past-window updates). Nothing is
        /// gated: the version works in full, and what comes back is the
        /// support reminder. Reachable only for licenses issued before updates
        /// became permanent, which carry a date at all.
        case buildNotCovered(LicensePayload)
        /// No usable license file on disk — missing, unverifiable, or revoked.
        ///
        /// This was `.trial(daysLeft:)` and `.expired`. They had already come
        /// to mean the same thing when the trial was removed, and the day count
        /// was inert: nothing gated on it and no UI showed it. Two states with
        /// trial-era names, in a product with no trial, is a standing invitation
        /// to re-derive a countdown from them.
        case unlicensed
    }

    @Published private(set) var state: State

    private let verifier: LicenseVerifier
    private let installClock: InstallClock
    private let licenseDirectory: URL
    private let blocklistCache: BlocklistCache
    private let alwaysEntitled: Bool
    /// UTC day this build shipped (Info.plist stamp) — nil for dev/MAS
    /// builds, which fail open in `evaluate()`.
    private let buildReleaseDate: Date?

    private var licenseURL: URL { licenseDirectory.appendingPathComponent("license.sealshotlicense") }

    static let shared: EntitlementStore = {
        let appSupport = AppSupportDirectory.sealshot
        return EntitlementStore(verifier: LicenseVerifier(),
                                installClock: .production(),
                                licenseDirectory: appSupport,
                                blocklistCache: BlocklistCache(directory: appSupport),
                                alwaysEntitled: AppInfo.edition == .mas,
                                buildReleaseDate: AppInfo.releaseDate)
    }()

    init(verifier: LicenseVerifier, installClock: InstallClock, licenseDirectory: URL,
         blocklistCache: BlocklistCache, alwaysEntitled: Bool,
         buildReleaseDate: Date? = nil) {
        self.verifier = verifier
        self.installClock = installClock
        self.licenseDirectory = licenseDirectory
        self.blocklistCache = blocklistCache
        self.alwaysEntitled = alwaysEntitled
        self.buildReleaseDate = buildReleaseDate
        self.state = .unlicensed
        self.state = evaluate()
    }

    /// Re-derive state from disk. Called at init and whenever something that
    /// feeds it changes (activation, removal, blocklist).
    private func evaluate(now: Date = Date()) -> State {
        // `alwaysEntitled` first, and it returns BEFORE the install stamp is
        // touched. `heal` writes to the keychain, and on that path there is
        // nothing to write it for — an always-entitled build never asks for
        // support, so it has no use for an install date. It is not merely
        // wasted work: the MAS test host launches straight into this and a
        // keychain write there stalls the runner before it can connect.
        if alwaysEntitled {
            return .licensed(LicensePayload(id: UUID(), name: "App Store", email: "",
                                            licenseType: .individual, issued: "", updatesThrough: "",
                                            seats: 1))
        }
        // For every real state, licensed or not: this is the only thing in the
        // app that seeds and heals the install stamp, and the support reminder
        // dates from it. The trial-era code did it only on the unlicensed
        // branch, because that was the only one that needed a day count — which
        // would now mean a licensed user's install date is first written
        // whenever their license lapses, and a wiped stamp store never
        // re-seeds until then. `heal` is earliest-wins, so calling it often is
        // free.
        installClock.heal(now: now)
        if let text = try? String(contentsOf: licenseURL, encoding: .utf8),
           let payload = try? verifier.verify(fileText: text),
           blocklistCache.load()?.revokes(payload.id) != true {
            if UpdatePolicy.coversRunningBuild(buildReleasedAt: buildReleaseDate,
                                               payload: payload) {
                return .licensed(payload)
            }
            return .buildNotCovered(payload)
        }
        return .unlicensed
    }

    func refresh() { state = evaluate() }

    /// The stored license, or nil when there is none, it no longer verifies,
    /// or it has been revoked. An unusable file is treated as absent rather
    /// than as a comparison basis — otherwise corruption would permanently
    /// block activation. A revoked license is unusable for exactly the same
    /// reason, and `evaluate()` already ignores it: without this, a customer
    /// whose refunded license was revoked would be shown as unlicensed by
    /// the status card while activating their replacement raised a
    /// destructive "This Mac is licensed to Jane Doe. Replace it with the
    /// license for Jane Doe?" dialog naming the license the app claims not
    /// to have.
    private func storedPayload() -> LicensePayload? {
        guard let text = try? String(contentsOf: licenseURL, encoding: .utf8),
              let payload = try? verifier.verify(fileText: text),
              blocklistCache.load()?.revokes(payload.id) != true
        else { return nil }
        return payload
    }

    /// `text` is the full `.sealshotlicense` file contents (preamble + blob
    /// line) — read from a file opened via the panel or dropped onto the
    /// License tab. The FULL text is persisted, not just the envelope, so
    /// re-evaluation on relaunch re-verifies the preamble hash exactly as
    /// activation did.
    ///
    /// Compares the offered file against whatever is currently stored so a
    /// stale email attachment can never silently shorten a paid-for update
    /// window (see `ActivationOutcome`).
    @discardableResult
    func activate(_ text: String) throws -> ActivationOutcome {
        let offered = try verifier.verify(fileText: text)
        if blocklistCache.load()?.revokes(offered.id) == true { throw LicenseError.revoked }

        guard let current = storedPayload() else {
            try write(text)
            return .installed(offered)
        }
        guard current.id == offered.id else {
            return .needsConfirmation(current: current, offered: offered)
        }
        // Compare parsed days, not strings, so formatting can't affect ordering.
        // Unparseable dates fall through to install — same fail-open rule as
        // UpdatePolicy; bad data must never strand a paying customer.
        if let currentDay = current.updatesThroughDate,
           let offeredDay = offered.updatesThroughDate {
            if offeredDay < currentDay { return .olderRejected(current: current, offered: offered) }
            if offeredDay == currentDay { return .alreadyInstalled }
        }
        try write(text)
        return .installed(offered)
    }

    /// Second half of `.needsConfirmation` — call only after the user accepts.
    @discardableResult
    func confirmActivation(_ text: String) throws -> LicensePayload {
        let payload = try verifier.verify(fileText: text)
        if blocklistCache.load()?.revokes(payload.id) == true { throw LicenseError.revoked }
        try write(text)
        return payload
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: licenseDirectory,
                                                withIntermediateDirectories: true)
        try text.write(to: licenseURL, atomically: true, encoding: .utf8)
        state = evaluate()
    }

    func removeLicense() {
        try? FileManager.default.removeItem(at: licenseURL)
        state = evaluate()
    }

    func apply(blocklist: Blocklist) {
        blocklistCache.save(blocklist)
        state = evaluate()
    }
}

extension EntitlementStore {
    /// NOTHING is gated. Sealshot is free to use: every feature works, no capture
    /// or recording is ever refused, and no state expires into uselessness. What
    /// a license buys is that the support reminder stops — see
    /// `SupportNudgePolicy`.
    ///
    /// Kept as a named property rather than deleted at the call sites, because
    /// "does licensing block this?" is a question worth being able to answer in
    /// one place, and the answer being permanently `false` is the product
    /// decision, not an oversight.
    nonisolated static func blocksCreation(state: State) -> Bool { false }

    var blocksCreation: Bool { false }

    /// Any valid, unrevoked license file — this person already paid. The
    /// covered-build distinction used to matter here because a lapsed window
    /// bringing the reminder back was what kept a renewal worth buying;
    /// renewals are gone, so `.buildNotCovered` now counts. Sealshot is
    /// donation-supported and no new files are issued — this exists to
    /// grandfather the ones already out there. The honor flag
    /// (`SupportNudgeStore.isAcknowledged`) is the live mechanism, and is
    /// deliberately NOT this store's business: it is a statement by the user,
    /// not a property of a license.
    nonisolated static func isSupported(state: State) -> Bool {
        switch state {
        case .licensed, .buildNotCovered: return true
        case .unlicensed: return false
        }
    }

    var isSupported: Bool { Self.isSupported(state: state) }

    /// Route the user to the License tab. Reached from the support reminder and
    /// from "I Already Donated". The pending deep-link is set BEFORE posting so
    /// a not-yet-open Settings window still lands on License once it mounts (see
    /// `SettingsDeepLink`).
    func presentLicenseSettings() {
        SettingsDeepLink.pendingSection = .license
        NotificationCenter.default.post(name: .openLicenseSettings, object: nil)
    }
}

enum UpdatePolicy {
    /// Unlicensed users may always update — there is nothing to consume.
    /// Licensed users get updates published on or before their updatesThrough
    /// day (inclusive, +1 day of slack for timezone edges). Unparseable dates
    /// fail OPEN, which is also how a PERMANENT license reads: its
    /// updatesThrough is empty, so it never limits anything.
    static func allowsUpdate(publishedAt: Date?, state: EntitlementStore.State) -> Bool {
        let licensePayload: LicensePayload?
        switch state {
        case .licensed(let p), .buildNotCovered(let p): licensePayload = p
        case .unlicensed: licensePayload = nil
        }
        guard let payload = licensePayload,
              let published = publishedAt,
              let through = payload.updatesThroughDate
        else { return true }
        return published <= through.addingTimeInterval(86_400)
    }

    /// Whether the RUNNING build falls inside the license's updates window —
    /// the install-time counterpart of `allowsUpdate` (which gates Sparkle).
    /// A user can always download the newest DMG manually; this is what
    /// keeps that from bypassing the window. Same fail-open + 1-day-slack
    /// rules as `allowsUpdate`: nil stamp (dev/MAS builds) or unparseable
    /// updatesThrough never gates.
    static func coversRunningBuild(buildReleasedAt: Date?, payload: LicensePayload) -> Bool {
        guard let released = buildReleasedAt,
              let through = payload.updatesThroughDate
        else { return true }
        return released <= through.addingTimeInterval(86_400)
    }
}
