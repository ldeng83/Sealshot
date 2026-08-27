import AppKit
import SwiftUI

/// The shapes the top-of-window banner can take — both of them now about a
/// PAID license's update window, because Sealshot is free to use and there is
/// no countdown left to run. An unlicensed user sees no banner at all; the
/// occasional `SupportNudge` is the whole of the ask.
///
/// `.buildNotCovered` covers a license whose update window predates the running
/// build, `.updatesLapsingSoon` one that is about to. Neither blocks anything —
/// they exist so a lapsed window is discoverable rather than silent.
enum LicenseBannerKind: Equatable {
    case buildNotCovered(updatesThrough: String)
    /// A valid license whose update window closes within
    /// `updatesLapsingWindowDays`.
    case updatesLapsingSoon(daysLeft: Int)
}

/// Pure show/hide policy for the banner — no view code, no side effects,
/// fully unit-testable in isolation from AppKit/SwiftUI.
enum LicenseBannerPolicy {
    /// How many days out from a license's `updatesThrough` date the
    /// `.updatesLapsingSoon` nudge starts showing.
    static let updatesLapsingWindowDays = 30

    /// `dismissed` is what the user dismissed THIS app session (nil if
    /// nothing). Dismissal is scoped to the day count: dismissing at
    /// daysLeft == N suppresses it only while the current daysLeft stays >=
    /// N (a smaller daysLeft — the window ticking closer — re-shows it).
    /// `.buildNotCovered` has no day count and is not dismissible: it is the
    /// only place the app says why the newest features are missing.
    static func banner(for state: EntitlementStore.State,
                       dismissed: LicenseBannerKind?,
                       now: Date = Date()) -> LicenseBannerKind? {
        switch state {
        case .licensed(let payload):
            // Empty updatesThrough = a PERMANENT license (and the MAS/dev
            // path): there is no window, so there is nothing to nudge about.
            guard let through = payload.updatesThroughDate else { return nil }
            let days = Int(through.timeIntervalSince(now) / 86_400)
            guard days >= 0, days <= updatesLapsingWindowDays else { return nil }
            if case .updatesLapsingSoon(let dismissedAt) = dismissed, days >= dismissedAt {
                return nil
            }
            return .updatesLapsingSoon(daysLeft: days)
        case .unlicensed:
            // No license: nothing to say here. Every feature works, so a banner
            // would be advertising, and advertising in the window someone is
            // trying to work in is exactly what this model rejects.
            return nil
        case .buildNotCovered(let payload):
            return .buildNotCovered(updatesThrough: payload.updatesThrough)
        }
    }
}

/// Slim horizontal bar shown across the top of the main window content
/// (below the toolbar, above every tab) while `LicenseBannerPolicy` returns a
/// kind. Purely presentational — the host (EditorWindowController) owns the
/// policy evaluation, the session `dismissed` state, and the show/hide
/// layout; this view just renders one `kind` and forwards taps.
struct LicenseBannerView: View {
    let kind: LicenseBannerKind
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(1)
            Button("Open License Settings", action: onOpenSettings)
                .buttonStyle(.link)
                .font(.callout)
            Spacer(minLength: 8)
            // The lapsing-soon nudge is dismissible; buildNotCovered stays,
            // because it explains missing features nothing else accounts for.
            if isDismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: Theme.surfaceColor))
        .overlay(Divider(), alignment: .bottom)
    }

    private var isDismissible: Bool {
        switch kind {
        case .updatesLapsingSoon: return true
        case .buildNotCovered: return false
        }
    }

    private var iconName: String {
        switch kind {
        case .updatesLapsingSoon: return "clock"
        case .buildNotCovered: return "exclamationmark.triangle.fill"
        }
    }

    private var message: String {
        switch kind {
        case .buildNotCovered(let through):
            return "This version of Sealshot is newer than your license covers (updates through \(through))"
        case .updatesLapsingSoon(let daysLeft):
            return "Your update window closes in \(daysLeft) day\(daysLeft == 1 ? "" : "s") "
                + "— the app keeps working either way"
        }
    }
}
