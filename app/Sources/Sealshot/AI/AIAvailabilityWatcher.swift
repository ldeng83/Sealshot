import Foundation
import AppKit

extension Notification.Name {
    /// Posted (main thread) when `AIAvailability.status` is observed to have
    /// changed since the watcher last checked it — e.g. the user switched
    /// back to Sealshot after flipping Apple Intelligence in System
    /// Settings. `object` is nil; there is no per-capture target, this is a
    /// process-wide fact. Listeners re-derive whatever they need from
    /// `AIAvailability.status` themselves — this notification only says
    /// "go look again," it carries no payload of its own.
    static let aiAvailabilityDidChange = Notification.Name("com.seal-shot.aiAvailabilityDidChange")
}

/// Watches for Apple Intelligence availability changing while Sealshot runs.
///
/// `AIAvailability.status` is a poll, not a push — nothing in the framework
/// tells Sealshot when it changes. Every existing reader (Info-panel
/// generation gating, the Settings status row) only re-checks it at moments
/// that already have some other reason to run, so turning Apple Intelligence
/// on with a capture already open dropped the "needs Apple Intelligence"
/// copy on the next unrelated refresh without ever re-arming generation, and
/// the Settings row went stale the same way.
///
/// The one moment worth re-checking is the app coming back to the
/// foreground — returning from System Settings is exactly that. This
/// watcher hooks `NSApplication.didBecomeActiveNotification`, compares the
/// freshly read status against the last one it saw, and posts
/// `.aiAvailabilityDidChange` only when it actually changed, so an ordinary
/// app switch (nothing changed) costs nothing beyond the read itself — no
/// manifest re-read, no re-arm.
///
/// One process-wide instance: `didBecomeActive` is an app-level event, not a
/// per-window one, so there is exactly one "last seen" status to compare
/// against, no matter how many editor windows or Settings panes are open.
@MainActor
final class AIAvailabilityWatcher {
    static let shared = AIAvailabilityWatcher()

    private var lastSeenStatus: AIStatus?
    private var observer: NSObjectProtocol?

    private init() {}

    /// Idempotent — safe to call from every consumer's own setup path (an
    /// `EditorWindowController` init, a `SettingsView.onAppear`, …) without
    /// coordinating who "owns" starting it.
    func start() {
        guard observer == nil else { return }
        // Seed the baseline silently: the first read of this process is not
        // a "change," see `shouldPost`.
        lastSeenStatus = AIAvailability.status
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForChange()
            }
        }
    }

    /// Pure decision: is a freshly observed status worth telling the rest of
    /// the app about?
    ///
    /// `previous == nil` means this process has never observed a status
    /// before — there is nothing to compare against, so it is not a
    /// "change" and this returns false. Treating the first observation as a
    /// change would post on the very first `didBecomeActive` of every
    /// launch (macOS fires it during normal startup), which is a moment
    /// every existing caller already handles via its own open/initial-load
    /// path — a redundant post there does no harm, but tests should pin the
    /// decision explicitly rather than leave it to fall out of `!=` on an
    /// `Optional<AIStatus>` comparison.
    nonisolated static func shouldPost(previous: AIStatus?, current: AIStatus) -> Bool {
        guard let previous else { return false }
        return previous != current
    }

    /// Reads the current status, decides via `shouldPost`, and posts if so.
    /// Always updates the stored baseline to the freshly read value —
    /// whether or not it posted — so the next check compares against what
    /// is actually current.
    private func checkForChange() {
        let current = AIAvailability.status
        let shouldPost = Self.shouldPost(previous: lastSeenStatus, current: current)
        lastSeenStatus = current
        if shouldPost {
            NotificationCenter.default.post(name: .aiAvailabilityDidChange, object: nil)
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
