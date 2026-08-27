import AppKit
import ApplicationServices

/// Gate for driving another app's scroll view: needs the Accessibility
/// trust grant, and is impossible in the sandboxed (MAS) build — posting
/// input events is Direct-only, per the scroll-capture spec.
enum AccessibilityPermission {
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Trust check that must NEVER prompt — the permission checklist polls
    /// it every second, and any API with a prompt side effect puts an OS
    /// consent dialog next to our panel.
    ///
    /// HARD-WON: AXIsProcessTrusted() is the ONLY correct query here. It
    /// tracks kTCCServiceAccessibility — the service the System Settings
    /// "Accessibility" toggle actually writes (verified in the TCC db).
    /// The seemingly-equivalent alternatives all failed:
    ///  • event-tap probe — prompts when the TCC entry is absent;
    ///  • CGPreflightPostEventAccess — surfaced the "(Events)" dialog;
    ///  • IOHIDCheckAccess(kIOHIDRequestTypePostEvent) — reads
    ///    kTCCServicePostEvent, which the Settings toggle never writes, so
    ///    it reports missing even when Accessibility is granted.
    ///
    /// NOTE: macOS caches the Accessibility grant per-process. A *grant* is
    /// picked up live (false→true), but a *revocation* is NOT reflected until
    /// the app is relaunched — no query API reports it sooner. Detecting a
    /// mid-run revocation therefore requires observing the actual auto-scroll
    /// failing, not this trust bit.
    static var canAutoScroll: Bool {
        !isSandboxed && AXIsProcessTrusted()
    }

    /// Set when a LIVE auto-scroll attempt proves the grant is gone even though
    /// the cached AXIsProcessTrusted() query above still reports it present (see
    /// the note on `canAutoScroll`). The permission checklist's Accessibility
    /// row honours this to show the revocation the query can't, and it's
    /// cleared the moment the user acts on it (a re-grant applies live) or a
    /// fresh auto attempt confirms trust by creating its event tap.
    static var autoScrollRevoked = false

    /// Deep-link to System Settings → Privacy & Security → Accessibility.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ask macOS to register this app in the Accessibility list (and show
    /// its consent dialog when there's no entry yet). The list entry is only
    /// ever CREATED by this call — so when the user removes Sealshot from
    /// the list, calling again on the next trigger re-adds it, saving them
    /// the manual "+" dance. Safe to call on every failed gate: the OS
    /// suppresses the dialog whenever an entry (checked or not) exists.
    static func requestRegistration() {
        guard !isSandboxed else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

/// Optional capability on a `ScrollInjecting`: exact page geometry from the
/// content itself. The controller uses `isAtBottom` to finish the instant the
/// page reports end-of-content, instead of inferring it from stalled frames.
/// (AXScrollDriver reports it from the scroll bar's AXValue.)
protocol ScrollPositionReporting {
    var isAtBottom: Bool { get }
}

/// Posts the synthetic scroll input for auto-scroll capture.
protocol ScrollInjecting {
    /// Park the pointer inside the region so scroll events route to the
    /// window under it. `point` is in global AppKit (bottom-left) coords.
    func parkPointer(atGlobal point: CGPoint)
    /// One discrete step scrolling the content down the page by `points`.
    func scrollContentDown(points: Int) async
    /// The capture session is over — close any open gesture stream.
    func sessionEnded()
}

extension ScrollInjecting {
    func sessionEnded() {}
}

/// Real injector: tagged CGEvents so the takeover monitor can tell our
/// synthetic scrolling from the user's.
final class CGScrollInjector: ScrollInjecting {
    /// Marks events posted by us in `eventSourceUserData`.
    static let syntheticTag: Int64 = 0x5EA15C07   // "Sealshot scroll"

    /// Whether the auto-mode scroll-block tap should let an event pass (our
    /// own synthetic scroll) rather than swallow it (the user's input).
    ///
    /// Two independent fingerprints, OR'd so either suffices: the
    /// `eventSourceUserData` tag we stamp, and our own process id. The tag is
    /// the precise marker, but that custom field doesn't reliably survive a
    /// post→tap round-trip on every macOS version — and when it's lost, a
    /// tag-only check makes the tap eat our OWN scroll, so auto-scroll silently
    /// does nothing (observed on a user's machine: cursor parked correctly but
    /// the page never moved). Posted events carry our pid in
    /// `eventSourceUnixProcessID`; the user's hardware scroll does not, so the
    /// pid rule passes ours without ever passing theirs.
    static func shouldPassThroughBlockTap(
        eventType: CGEventType, userData: Int64, sourcePID: Int64, ourPID: Int64
    ) -> Bool {
        guard eventType == .scrollWheel else { return false }
        if userData == syntheticTag { return true }
        return ourPID != 0 && sourcePID == ourPID
    }

    private let source: CGEventSource?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        source?.userData = Self.syntheticTag
    }

    // Delivery notes from field experiments (keep — hard-won):
    // • postToPid delivery is IGNORED by Chromium for wheel events (page
    //   never moves) — scroll input must arrive via the system HID stream.
    // • Posting a located event into the HID stream makes the WindowServer
    //   move the REAL cursor to the event location — so a "virtual" park
    //   spot is impossible on this path. The pointer must be physically
    //   parked (once, at session start) and locked for the session.
    func parkPointer(atGlobal point: CGPoint) {
        // CG global coords are top-left-origin relative to the primary
        // display; AppKit global coords are bottom-left of the same.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primaryHeight - point.y))
    }

    /// One step, replicating the SNIFFED Shottr recipe field-for-field
    /// (listen-only tap capture of a working session on the exact page that
    /// walls us): plain discrete wheel — NO scroll/momentum phases —
    /// continuous(pixel) flavor with BOTH the point delta and the derived
    /// line delta populated (dY(pt) −100 / dY(line) −10 in the capture;
    /// hijack JS reading event.deltaY in line mode sees 0 if the line field
    /// is left empty). The gesture/burst experiments are reverted: Shottr
    /// punches the same page with none of that.
    func scrollContentDown(points: Int) async {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
            wheel1: -Int32(points), wheel2: 0, wheel3: 0)
        else { return }
        // Stamp the tag on the event itself too (not just the source): the
        // block tap's primary check reads it back, and event-level fields
        // survive the post→tap round-trip more reliably than source userData.
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        // Explicit line delta (points/10, min 1), matching the sniffed recipe.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1,
                                   value: Int64(-max(1, points / 10)))
        event.post(tap: .cghidEventTap)
    }
}
