import Foundation
#if canImport(Sparkle)
import Sparkle

/// Enforces the license's updates-through window. Sparkle calls this before
/// offering an update; SUAppcastItem.date is the item's pubDate.
///
/// SPUUpdaterDelegate is declared NS_SWIFT_UI_ACTOR (@MainActor), so this
/// witness is compiler-checked main-actor-isolated — reading the @MainActor
/// EntitlementStore.shared.state directly is safe with no runtime assertion
/// or queue hop needed.
private final class UpdatePolicyDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater,
                 shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        let state = EntitlementStore.shared.state
        guard !UpdatePolicy.allowsUpdate(publishedAt: updateItem.date, state: state) else { return }
        throw NSError(domain: "com.seal-shot.sealshot.license", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "This update was released after your license's update window. Sealshot keeps working — renew at seal-shot.com to get new versions.",
        ])
    }
}
#endif

/// Thin facade over Sparkle so call sites never touch Sparkle types.
/// `canImport(Sparkle)` is true only for Sealshot-Direct (the only target
/// that links the package), so the MAS build compiles the inert branch.
/// The updater is not started automatically; call `startUpdater()` from
/// AppDelegate after the app has finished launching.
@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    /// Re-publish so SwiftUI re-reads `automaticallyChecksForUpdates`.
    ///
    /// The toggle in Settings binds to this object, and a SwiftUI Toggle keeps
    /// its own optimistic state — so anything that touches the updater without
    /// SwiftUI knowing leaves the switch showing whatever it last drew. Clicking
    /// **Check Now** did exactly that: the setting stayed off (Sparkle never
    /// writes it for a user-initiated check) while the switch redrew as on.
    /// Same shape as the Launch at login switch flipping on its own, fixed the
    /// same way — by telling SwiftUI to look again rather than trusting it.
    func refreshPublishedState() { objectWillChange.send() }

#if canImport(Sparkle)
    // Built with SPUUpdater + a custom user driver (rather than
    // SPUStandardUpdaterController) so the "no update found" / error popups use
    // our centered-icon card instead of Sparkle's left-pinned NSAlert. Everything
    // else stays Sparkle-standard. See CenteredUpdateUserDriver.
    private let updater: SPUUpdater
    private let userDriver: CenteredUpdateUserDriver
    private let policyDelegate = UpdatePolicyDelegate()

    private init() {
        userDriver = CenteredUpdateUserDriver(hostBundle: .main, delegate: nil)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: userDriver, delegate: policyDelegate)
    }

    func startUpdater() {
        do {
            try updater.start()
        } catch {
            NSLog("Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }

    var updatesAreSupported: Bool { true }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    func checkForUpdates() {
        updater.checkForUpdates()
        // A manual check must not appear to change the preference. Sparkle does
        // not change it, so re-publishing is enough to put the switch back to
        // the truth.
        refreshPublishedState()
    }

    /// Bridges SPUUpdater, which persists the preference itself.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }
#else
    private init() {}

    func startUpdater() {}

    var updatesAreSupported: Bool { false }

    var canCheckForUpdates: Bool { false }

    func checkForUpdates() {}

    var automaticallyChecksForUpdates: Bool {
        get { false }
        set {}
    }
#endif

    /// "0.3.0 (5)" — marketing version plus build number.
    var currentVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
