import SwiftUI

/// State of one required permission, queried fresh on every poll tick.
enum PermissionState: Equatable {
    case granted
    case missing
    /// Granted in System Settings, but macOS enforces it at launch — the
    /// app must relaunch before it takes effect (Screen Recording).
    case needsRelaunch
}

/// One permission an action shows in its checklist: live state + how to
/// enable it. The `enable` closure is the ONLY place a system consent
/// dialog may fire — panels and OS dialogs must never appear in the same
/// beat, so dialogs come exclusively from a user click on a row's Enable
/// button. Non-required rows display their status but never block the
/// action (the checklist always lists every permission with its state).
struct PermissionRequirement: Identifiable {
    let id: String
    let title: String
    let detail: String
    /// False = informational row: status shown, doesn't gate the action.
    let isRequired: Bool
    /// macOS only applies the grant at launch (Screen Recording) — after
    /// Enable, the running app is blind to it, so the row must offer a
    /// relaunch instead of waiting for a state flip that can't come.
    let grantNeedsRelaunch: Bool
    let state: @MainActor () async -> PermissionState
    let enable: @MainActor () -> Void
}

extension PermissionRequirement {
    @MainActor static func screenRecording(required: Bool = true) -> PermissionRequirement {
        PermissionRequirement(
            id: "screen-recording",
            title: "Screen Recording",
            detail: "Required to capture anything on screen.",
            isRequired: required,
            grantNeedsRelaunch: true,
            state: {
                // Don't touch ScreenCaptureKit while the TCC entry is
                // missing — SCShareableContent fires the system consent
                // dialog on a fresh state, and dialogs only come from Enable.
                guard CGPreflightScreenCaptureAccess() else { return .missing }
                return await ScreenRecordingPermission.liveGranted() ? .granted : .needsRelaunch
            },
            enable: {
                CGRequestScreenCaptureAccess()   // creates the entry (no-op if present)
                ScreenRecordingPermission.openSystemSettings()
            })
    }

    @MainActor static func microphone(required: Bool = false) -> PermissionRequirement {
        PermissionRequirement(
            id: "microphone",
            title: "Microphone",
            detail: "Used only when you record your microphone into a screen recording.",
            isRequired: required,
            grantNeedsRelaunch: false,
            state: { RecordingPermission.microphoneAuthorized ? .granted : .missing },
            enable: { RecordingPermission.enableMicrophone() })
    }

    @MainActor static func accessibilityAutoScroll(required: Bool = true) -> PermissionRequirement {
        PermissionRequirement(
            id: "accessibility",
            title: "Accessibility",
            detail: "Used by scrolling capture: lets Sealshot auto-scroll the page for you.",
            isRequired: required,
            grantNeedsRelaunch: false,
            state: {
                // A live auto-scroll attempt can prove the grant is gone while
                // AXIsProcessTrusted() is still cached true — honour that here,
                // otherwise the row would falsely read granted after a
                // mid-session revocation.
                if AccessibilityPermission.autoScrollRevoked { return .missing }
                return AccessibilityPermission.canAutoScroll ? .granted : .missing
            },
            enable: {
                // The user is re-granting; a re-grant applies live, so drop the
                // revoked latch now and let the row poll the query again.
                AccessibilityPermission.autoScrollRevoked = false
                AccessibilityPermission.requestRegistration()   // re-adds the list entry
                AccessibilityPermission.openSystemSettings()
            })
    }

}

extension PermissionRequirement {
    /// The app's full permission set, shared by Settings ▸ Permissions and the
    /// welcome tour's final card so they never drift.
    @MainActor static func appRequirements() -> [PermissionRequirement] {
        var rows = [PermissionRequirement.screenRecording()]
        // Accessibility is Direct-only (the MAS sandbox blocks auto-scroll).
        if !AccessibilityPermission.isSandboxed {
            rows.append(.accessibilityAutoScroll())
        }
        rows.append(.microphone(required: true))
        return rows
    }

    /// Permissions to show on the plain capture prompt: the same full set as the
    /// welcome tour and Settings (so it doesn't look like fewer permissions
    /// exist), but only Screen Recording gates the Capture action — capturing a
    /// screenshot needs nothing else. `accessibilityRequired` lets scrolling
    /// capture (which shares this list) additionally gate on Accessibility when
    /// auto-scroll is on. `sandboxed` is injected for testing.
    @MainActor static func captureRequirements(
        accessibilityRequired: Bool = false,
        sandboxed: Bool = AccessibilityPermission.isSandboxed
    ) -> [PermissionRequirement] {
        var rows = [PermissionRequirement.screenRecording()]
        if !sandboxed {
            rows.append(.accessibilityAutoScroll(required: accessibilityRequired))
        }
        rows.append(.microphone(required: false))
        return rows
    }
}

/// Aggregate of the list's live state, for hosts that gate actions on it.
struct PermissionStatusSummary: Equatable {
    var requiredGranted = false
    /// A grant was made (or attempted) that the running app can't apply
    /// until relaunch — the host should offer a Relaunch action.
    var relaunchPending = false
}

/// The live-polled permission rows — shared by the capture checklist panel
/// and Settings → Permissions, so the two always look and behave the same.
/// Each row shows status (polled, so granting in System Settings flips it
/// without re-triggering) and an Enable button while missing.
struct PermissionStatusList: View {
    let requirements: [PermissionRequirement]
    /// Show the "optional here" badge on non-required rows. Off for the capture
    /// prompt, which lists every permission plainly with just its explanation.
    var showsOptionalBadge: Bool = true
    var onSummaryChange: ((PermissionStatusSummary) -> Void)?

    @State private var states: [String: PermissionState] = [:]
    /// Rows whose Enable was clicked — drives the post-Enable relaunch
    /// guidance for grants the running app can't observe.
    @State private var enableClicked: Set<String> = []

    var body: some View {
        VStack(spacing: 10) {
            ForEach(requirements) { row($0) }
        }
        .task { await pollStates() }
    }

    /// macOS applies some grants only at launch, so after Enable the
    /// running app may be blind to the change — flag the relaunch instead
    /// of waiting for a state flip that can't arrive.
    private func blindAfterEnable(_ req: PermissionRequirement) -> Bool {
        states[req.id] == .missing
            && req.grantNeedsRelaunch && enableClicked.contains(req.id)
    }

    private func row(_ req: PermissionRequirement) -> some View {
        let state = states[req.id]
        // After Enable, a relaunch-only grant (Screen Recording) can't be
        // observed by the running app — surface the relaunch indicator instead
        // of leaving the empty circle + Enable button as if nothing happened.
        let showRelaunch = state == .needsRelaunch || blindAfterEnable(req)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: showRelaunch ? "arrow.triangle.2.circlepath.circle.fill" : icon(for: state))
                .font(.system(size: 18))
                .foregroundStyle(showRelaunch ? .orange : color(for: state))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(req.title).font(.callout.weight(.semibold))
                    if showsOptionalBadge && !req.isRequired {
                        Text("optional here")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle(for: req, state: state))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if state == .granted {
                Text("Granted").font(.caption).foregroundStyle(.secondary)
            } else if showRelaunch {
                Text("Relaunch required").font(.caption).foregroundStyle(.orange)
            } else {
                Button("Enable…") {
                    enableClicked.insert(req.id)
                    req.enable()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func subtitle(for req: PermissionRequirement, state: PermissionState?) -> String {
        if state == .needsRelaunch { return "Enabled — relaunch Sealshot to apply." }
        if blindAfterEnable(req) { return "Enabled it in System Settings? Relaunch Sealshot to apply." }
        return req.detail
    }

    private func icon(for state: PermissionState?) -> String {
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .needsRelaunch: return "arrow.triangle.2.circlepath.circle.fill"
        default: return "circle"
        }
    }

    private func color(for state: PermissionState?) -> Color {
        switch state {
        case .granted: return .green
        case .needsRelaunch: return .orange
        default: return .secondary
        }
    }

    private func pollStates() async {
        while !Task.isCancelled {
            for req in requirements {
                states[req.id] = await req.state()
            }
            onSummaryChange?(PermissionStatusSummary(
                requiredGranted: requirements.filter(\.isRequired)
                    .allSatisfy { states[$0.id] == .granted },
                relaunchPending: requirements.contains {
                    states[$0.id] == .needsRelaunch || blindAfterEnable($0)
                }
            ))
            // Steady state (everything granted) is cheap to watch less often
            // — the granted path queries ScreenCaptureKit each tick.
            let allGranted = requirements.allSatisfy { states[$0.id] == .granted }
            try? await Task.sleep(nanoseconds: allGranted ? 5_000_000_000 : 1_000_000_000)
        }
    }
}

/// One panel for everything an action needs: the shared permission rows
/// plus a single footer action. The action button arms once every required
/// row is green — and becomes "Relaunch" whenever a grant is pending that
/// only a relaunch can apply.
struct PermissionChecklistView: View {
    let title: String
    let requirements: [PermissionRequirement]
    let actionLabel: String
    var showsOptionalBadge: Bool = true
    let onReady: () -> Void
    let onCancel: () -> Void

    @State private var summary = PermissionStatusSummary()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(title).font(.title3.bold())
            }

            Text("Enable each permission below — the list updates as you grant them.")
                .foregroundStyle(.secondary)

            PermissionStatusList(requirements: requirements,
                                 showsOptionalBadge: showsOptionalBadge) { summary = $0 }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if summary.relaunchPending {
                    Button("Relaunch") { AppRelauncher.relaunch() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(actionLabel, action: onReady)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!summary.requiredGranted)
                }
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 470)
    }
}
