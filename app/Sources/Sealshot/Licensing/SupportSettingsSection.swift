import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted to deep-link Settings straight to the Support tab — from the
    /// banner, and from shipped 0.8.0 builds' reminder buttons. The NAME still
    /// says License because the string is the contract with code already in
    /// the wild; the tab it opens is Support.
    static let openLicenseSettings = Notification.Name("sealshot.openLicenseSettings")
    /// Posted to deep-link Settings straight to Privacy & Security (e.g. the
    /// recovery-verify nudge's "Generate New…" action). Same dual mechanism
    /// as `.openLicenseSettings` — see `SettingsDeepLink`.
    static let openPrivacySettings = Notification.Name("sealshot.openPrivacySettings")
}

/// Pending Settings deep-link, set BEFORE either notification above is
/// posted. `SettingsView`'s `.onReceive` only fires while its view is
/// already mounted, so a nudge firing before Settings has ever been opened
/// would otherwise post to no listener and land on the default tab.
/// `.onAppear` consumes this once the view mounts, covering that case; the
/// `.onReceive` handlers consume it too, covering the already-mounted case.
/// Consumed (set nil) wherever it's read, so a stale value can never leak
/// into an unrelated later deep-link.
@MainActor enum SettingsDeepLink {
    static var pendingSection: SettingsView.Section?
}

/// Settings ▸ Support. Sealshot is donation-supported, and this tab is the
/// entire administration of that: a Donate link, and an "I've donated"
/// checkbox that silences the occasional reminder. The checkbox is the honor
/// system in one control — nothing verifies it, deliberately. The app's source
/// is open, so a check would be theater, and a donation model that
/// second-guesses its donors has misunderstood itself.
///
/// This replaced LicenseSettingsSection: activation, file drops, replacement
/// dialogs, renewal cards — all machinery for a product (license files) that
/// is no longer issued. A license file already installed is still read and
/// honored (`EntitlementStore` grandfathers it as supported); it simply has no
/// management UI, because there is nothing left to manage. Someone moving to a
/// new Mac ticks the box instead of hunting for a file.
struct SupportSettingsSection: View {
    @ObservedObject var entitlements: EntitlementStore
    /// Local mirror of the honor flag. SupportNudgeStore is plain defaults,
    /// not observable; the mirror is seeded on appear and written through on
    /// toggle, and the reminder path reads the store directly.
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Support Sealshot") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entitlements.isSupported || acknowledged
                              ? "heart.fill" : "heart")
                            .font(.system(size: 18))
                            .foregroundStyle(.pink)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle)
                            Text(statusSubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if !entitlements.isSupported {
                            Link("Donate…", destination: LicensingConfig.donateURL)
                        }
                    }

                    // Hidden once a grandfathered license answers the question —
                    // a checkbox under "thank you for supporting Sealshot" would
                    // ask it twice.
                    if !entitlements.isSupported {
                        Toggle(isOn: Binding(
                            get: { acknowledged },
                            set: { on in
                                acknowledged = on
                                if on {
                                    SupportNudgeStore.shared.acknowledge()
                                } else {
                                    SupportNudgeStore.shared.withdrawAcknowledgement()
                                }
                            })) {
                            Text("I've donated — stop the occasional reminder")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .onAppear { acknowledged = SupportNudgeStore.shared.isAcknowledged }
    }

    private var statusTitle: String {
        if entitlements.isSupported || acknowledged {
            return "Thank you for supporting Sealshot"
        }
        return "Free to use, funded by donations"
    }

    private var statusSubtitle: String {
        // A grandfathered license file still names its owner — the one thing
        // the artifact does that the checkbox cannot, so keep saying it.
        if case .licensed(let p) = entitlements.state, !p.name.isEmpty {
            return "Supporter license for \(p.name)."
        }
        if case .buildNotCovered(let p) = entitlements.state, !p.name.isEmpty {
            return "Supporter license for \(p.name)."
        }
        if acknowledged {
            return "The occasional reminder is off. Nothing else ever changed — "
                + "every feature was already yours."
        }
        return "Every feature is included and nothing expires. Donations of any "
            + "amount are what keep it being built."
    }
}
