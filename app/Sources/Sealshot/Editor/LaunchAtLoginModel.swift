import AppKit
import Foundation
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "settings")

/// The login-item registration, behind a protocol so the model is testable
/// without touching the real `SMAppService` (which mutates OS state and is
/// bundle-path sensitive).
protocol LaunchAtLoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

struct MainAppLaunchAtLoginService: LaunchAtLoginService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Source of truth for the "Launch at login" toggle.
///
/// The toggle used to bind straight to `SMAppService.mainApp.status`. That
/// status is OS state SwiftUI cannot observe, so nothing invalidated the view
/// when it changed and the drawn switch could repaint from a stale cached
/// value — the diagnostic trace caught the app regaining focus and flipping
/// the switch WITHOUT ever re-reading the binding, leaving the graphic
/// disagreeing with a registration that was in fact correct. Publishing the
/// value here gives every render something in the view graph to diff, and
/// `refresh()` on activation re-syncs from the OS at exactly the moment the
/// drift used to appear.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    static let shared = LaunchAtLoginModel()

    /// What the switch draws. Only `.enabled` reads as on: `.requiresApproval`
    /// (user hasn't allowed it in System Settings yet) and `.notFound` (the
    /// registration points at a bundle that no longer exists, typical after an
    /// in-place update) are both "not launching at login" as far as the user
    /// is concerned.
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: SMAppService.Status

    /// True when macOS is holding the request for approval in System Settings —
    /// the registration exists but won't run until the user allows it.
    var requiresApproval: Bool { status == .requiresApproval }

    private let service: LaunchAtLoginService
    private var observers: [NSObjectProtocol] = []

    init(service: LaunchAtLoginService = MainAppLaunchAtLoginService(),
         observesActivation: Bool = true) {
        self.service = service
        let status = service.status
        self.status = status
        self.isEnabled = (status == .enabled)

        // Re-sync whenever the app comes back to the front: the user may have
        // changed the login item in System Settings while we were away, and
        // this is the moment the stale-repaint bug used to surface.
        // The observer holds `self` weakly, so an instance that goes away
        // leaves an inert registration behind rather than a dangling call —
        // production only ever creates the long-lived `shared` model, and
        // tests opt out entirely.
        guard observesActivation else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(context: "didBecomeActive") }
            })
    }

    /// Re-read the OS status into the published state.
    func refresh(context: String = "refresh") {
        let new = LaunchAtLoginDiag.observedStatus(context: context, service: service)
        guard new != status else { return }
        status = new
        isEnabled = (new == .enabled)
    }

    /// Apply a new value, then re-read so the published state always reflects
    /// what the OS actually did rather than what was asked for.
    func setEnabled(_ enabled: Bool) {
        LaunchAtLoginDiag.note("setEnabled requested=\(enabled ? "on" : "off") "
                               + "before=\(LaunchAtLoginDiag.statusName(status))")
        do {
            if enabled {
                try service.register()
            } else if status == .notFound {
                // A `notFound` registration cannot be unregistered — the call
                // fails with "Operation not permitted". There is nothing to
                // switch off, so treat it as already off instead of surfacing
                // an error the user can do nothing about.
                LaunchAtLoginDiag.note("setEnabled off skipped — nothing registered (notFound)")
            } else {
                try service.unregister()
            }
        } catch {
            LaunchAtLoginDiag.note("setEnabled \(enabled ? "register" : "unregister") FAILED: \(error)")
            os_log("launch-at-login toggle failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
        // Unconditional: even a failed call must leave the switch showing the
        // real state rather than the requested one.
        let new = service.status
        status = new
        isEnabled = (new == .enabled)
        LaunchAtLoginDiag.note("setEnabled done after=\(LaunchAtLoginDiag.statusName(new)) "
                               + "isEnabled=\(isEnabled)")
    }
}
