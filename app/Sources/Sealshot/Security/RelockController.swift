import AppKit
import CoreGraphics

/// Locks the encryption session on system sleep / screen lock / fast-user
/// switch, and after a configurable idle interval. The trigger conditions
/// are injected so the policy is unit-testable without real NSWorkspace
/// events or a live event source.
///
/// Idle scope: "idle" means the *person* has stopped touching the Mac, not
/// that they have stopped touching Sealshot. We read the system-wide HID idle
/// time (`secondsSinceLastEventType`, the same signal screensavers use), so a
/// user actively working in another app is NOT considered idle. The
/// system-level sleep/screen-lock observers below cover the "walked away and
/// the Mac locked/slept" cases.
@MainActor
final class RelockController {
    private let isEnabledAndUnlocked: () -> Bool
    private let lock: () -> Void
    /// True while a capture or screen recording is in flight — we defer the
    /// idle lock rather than slam a re-auth wall over an unattended recording.
    private let isBusy: () -> Bool
    /// Seconds since the last system-wide hardware input. Injected for tests.
    private let systemIdleSeconds: () -> TimeInterval
    private var tokens: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private let idlePref: IdleLockPreference

    init(isEnabledAndUnlocked: @escaping () -> Bool,
         lock: @escaping () -> Void,
         idlePref: IdleLockPreference = IdleLockPreference(),
         isBusy: @escaping () -> Bool = { false },
         systemIdleSeconds: @escaping () -> TimeInterval = RelockController.hidIdleSeconds) {
        self.isEnabledAndUnlocked = isEnabledAndUnlocked
        self.lock = lock
        self.idlePref = idlePref
        self.isBusy = isBusy
        self.systemIdleSeconds = systemIdleSeconds
    }

    /// Seconds since the most recent hardware input of ANY kind, anywhere on
    /// the system (not just events routed to Sealshot). We take the minimum
    /// across the concrete input event types rather than the private
    /// "any input" constant, which is not a defined `CGEventType` case in Swift
    /// (force-unwrapping it would trap). No special permission is required to
    /// read this, and it works inside the sandbox.
    nonisolated static func hidIdleSeconds() -> TimeInterval {
        let inputTypes: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel]
        let idles = inputTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }
        return idles.min() ?? 0
    }

    /// Pure policy: should we auto-lock for inactivity right now?
    func shouldLockForIdle() -> Bool {
        let minutes = idlePref.minutes
        guard minutes > 0, isEnabledAndUnlocked() else { return false }
        // Never interrupt an in-flight capture or recording with a lock wall.
        if isBusy() { return false }
        return systemIdleSeconds() >= Double(minutes) * 60
    }

    /// The repeating timer's callback (also directly callable in tests).
    func idleTick() {
        if shouldLockForIdle() { lock() }
    }

    /// Called by each observed system event; locks only when meaningful.
    func handleSystemLockEvent() {
        guard isEnabledAndUnlocked() else { return }
        lock()
    }

    /// Begin observing system notifications. Call once at launch.
    func start() {
        let wsc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(wsc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSystemLockEvent() }
            })
        }

        // Coarse repeating timer — 15 s resolution is plenty since the idle
        // threshold is measured in whole minutes. Each tick reads the system
        // HID idle time directly, so there is no per-event bookkeeping to keep.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTick() }
        }
    }

    func stop() {
        let wsc = NSWorkspace.shared.notificationCenter
        tokens.forEach { wsc.removeObserver($0) }
        tokens = []
        idleTimer?.invalidate(); idleTimer = nil
    }

    // Inline teardown (not stop(), which is @MainActor and uncallable from a
    // nonisolated deinit): invalidate the timer directly. Workspace tokens
    // tolerate dealloc.
    deinit {
        idleTimer?.invalidate()
    }
}
