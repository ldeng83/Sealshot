import AppKit

/// Presents the support reminder — the one thing a license removes.
///
/// Placement is the whole design. It fires AFTER something has landed, never
/// before: a reminder standing between someone and the thing they opened the app
/// to do is a paywall wearing a friendlier hat. It also stays away while the
/// library is locked or another capture is running, and never appears twice in a
/// fortnight. When it is due is `SupportNudgePolicy`'s business; this type only
/// decides whether the moment is a decent one, and what the alert says.
@MainActor
enum SupportNudge {
    /// Where the buy page lives — deliberately not a price. Prices change on the
    /// website, and a number compiled into the app is a number that will one day
    /// be wrong in a shipped build.
    // /donate, though /buy still redirects there forever — the 0.8.0 binaries
    // carry the old path, and a link in a shipped binary cannot be taken back.
    static let donateURL = URL(string: "https://seal-shot.com/donate/")!

    /// Long enough for the editor window or the recording's reveal to settle, so
    /// the alert reads as a follow-up rather than an interruption.
    private static let settleDelay: TimeInterval = 2.0

    /// Whether the moment is a decent one to ask, as a pure function of the
    /// three things that make it a bad one.
    ///
    /// Extracted from the delayed block below so the rules can be tested at all.
    /// In place they were unreachable: reaching them meant getting past a
    /// two-second `asyncAfter`, and their inputs were `NSApp` and a global
    /// coordinator. The rules themselves are the part worth pinning — this is
    /// the code that decides whether a request for money lands on top of
    /// someone's work.
    ///
    /// - Parameters:
    ///   - isBusy: a capture or recording is running. Asking mid-capture is
    ///     precisely the interruption this whole design avoids.
    ///   - isLocked: the library is locked, so the user is being asked for Touch
    ///     ID, not for money.
    ///   - hasModal: something else already owns the screen; two stacked modals
    ///     is a bug in any case, and this is the one that should yield.
    static func shouldPresentNow(isBusy: Bool, isLocked: Bool, hasModal: Bool) -> Bool {
        !isBusy && !isLocked && !hasModal
    }

    /// Count a capture or recording that actually landed, then ask if it is time.
    ///
    /// - Parameter isBusy: re-checked at presentation time — the delay below is
    ///   long enough for the user to have started something else.
    static func recordCreationAndAskIfDue(isBusy: @escaping @MainActor () -> Bool,
                                          now: Date = Date()) {
        // Resolved here rather than as a default argument: default arguments are
        // evaluated in a nonisolated context, and the store is main-actor bound.
        let store = SupportNudgeStore.shared
        store.recordCreation()
        guard isDue(store: store, now: now) else { return }

        // Stamped now, before presenting: a reminder dismissed by closing the
        // window — or by the app quitting first — must still count as asked. The
        // alternative is someone who sees it every single launch.
        store.recordAsked(now: now)

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            guard shouldPresentNow(isBusy: isBusy(),
                                   isLocked: CaptureCoordinator.isLocked,
                                   hasModal: NSApp.modalWindow != nil) else {
                return          // Bad moment. The stamp holds; it asks again in a fortnight.
            }
            present()
        }
    }

    static func isDue(store: SupportNudgeStore, now: Date = Date()) -> Bool {
        guard !CaptureCoordinator.isLocked else { return false }
        // The honor flag counts exactly like a license: both mean "this person
        // has answered the question", and asking again after either is the nag
        // this design exists to avoid.
        guard !store.isAcknowledged else { return false }
        return SupportNudgePolicy.isDue(.init(
            firstRunAt: InstallClock.production().recordedStart,
            captureCount: store.captureCount,
            lastAskedAt: store.lastAskedAt,
            isSupported: EntitlementStore.shared.isSupported,
            now: now))
    }

    /// A window to hang the reminder off, or nil when there isn't one.
    ///
    /// nil is a normal state, not a failure: Sealshot captures with its window
    /// closed and can run entirely from the menu bar, which is exactly when the
    /// reminder is most likely to come due.
    private static var sheetHost: NSWindow? {
        guard let window = NSApp.mainWindow, window.isVisible,
              window.attachedSheet == nil else { return nil }
        return window
    }

    private static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Sealshot is free — and funded by donations"
        alert.informativeText =
            "Every feature is yours whether or not you ever give: nothing expires, "
            + "nothing is watermarked, and no capture is ever refused.\n\n"
            + "Donate any amount, once, and this reminder stops for good."
        alert.addButton(withTitle: "Donate…")
        alert.addButton(withTitle: "Remind Me Later")
        alert.addButton(withTitle: "I Already Donated")
        return alert
    }

    /// Window-modal when there is a window, app-modal only as the fallback.
    ///
    /// `NSAlert.runModal()` is the convention for the coordinators' messages,
    /// but those are permission failures and capture errors — things the user
    /// must answer before anything else can proceed. This is the least urgent
    /// message in the app, and app-modal costs it two things it can't afford:
    /// it blocks the main thread in a nested run loop, and it arrives detached
    /// from any window, so if focus moved during the two-second settle delay it
    /// surfaces over whatever the user switched to. A reminder that interrupts
    /// another app is the paywall-in-a-friendlier-hat this design exists to
    /// avoid. A sheet waits on Sealshot's own window instead.
    private static func present() {
        let alert = makeAlert()
        guard let host = sheetHost else {
            respond(to: alert.runModal())
            return
        }
        alert.beginSheetModal(for: host) { response in
            MainActor.assumeIsolated { respond(to: response) }
        }
    }

    private static func respond(to response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(donateURL)
        case .alertThirdButtonReturn:
            // Taken at its word, on the spot. Routing to Settings to find a
            // checkbox would make "I already donated" homework; the flag is the
            // whole mechanism, so set it here and be done.
            SupportNudgeStore.shared.acknowledge()
        default:
            break                       // Later: the stamp above already handled it.
        }
    }
}
