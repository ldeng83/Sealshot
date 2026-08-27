import AppKit
import os.log

private let tourLog = OSLog(subsystem: "com.seal-shot.sealshot", category: "welcome-tour")

/// Puts the first-launch welcome tour card on screen above the editor window.
///
/// The card and the editor both open in the same runloop turn at launch, and
/// the editor raises itself to `.floating` and re-fronts itself 0.25s later
/// (`EditorController.raiseAboveOtherApps`) — which used to bury the card.
/// Attaching the card as a CHILD of the editor sidesteps the race entirely:
/// AppKit keeps a child "in relative position … for subsequent ordering
/// operations involving either window", so no level juggling is needed.
///
/// Deliberately NOT a floating panel: window levels are system-wide, so a
/// raised card would also sit on top of every other app's windows. Apple's own
/// criteria for `isFloatingPanel` want a panel that must stay visible while the
/// user works in the app's standard windows — a one-time tour isn't that.
enum WelcomeWindowOrdering {

    /// Show `card` pinned above `parent` (the editor window). With no parent —
    /// the editor failed to open, or is locked behind the unlock overlay — the
    /// card raises itself to open in front, then settles back to `.normal` so
    /// it can't strand itself on top of other apps.
    @MainActor
    static func present(_ card: NSWindow, above parent: NSWindow?) {
        // A window can't parent itself; Apple warns against parent/child cycles.
        if let parent, parent !== card {
            card.level = .normal
            parent.addChildWindow(card, ordered: .above)
            card.makeKeyAndOrderFront(nil)
            keepPinnedWhileOnTheSameDisplay(card, parent: parent)
            // AppKit orders children out with their parent. Closing the editor
            // (⌘W) mid-tour would take the card with it and leave no way to
            // finish or dismiss it, so cut it loose and let it stand alone.
            WindowCloseCleanup.onClose(of: parent) { [weak card] in
                guard let card else { return }
                parent.removeChildWindow(card)
                card.orderFront(nil)
            }
        } else {
            card.level = .floating
            card.makeKeyAndOrderFront(nil)
            card.orderFrontRegardless()
            DispatchQueue.main.async { card.level = .normal }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep the card a child of the editor while they share a display, and only
    /// while they share a display.
    ///
    /// Being a child is what pins the card above the editor — that is the whole
    /// point, and clicking the editor must never bury the tour. But a child
    /// window is bound to its parent's DISPLAY: dragged to another screen it is
    /// not closed, not occluded and not off-screen — AppKit keeps reporting
    /// `isVisible == true`, `isOnActiveSpace == true`, occlusion `.visible`,
    /// `alphaValue == 1` and a frame squarely inside that screen's bounds — yet
    /// the window server never composites it, so it is simply never drawn.
    /// Nothing raises it again either: `makeKeyAndOrderFront` reports success
    /// and changes nothing.
    ///
    /// So the relationship is maintained dynamically: dropped on another
    /// display the card becomes an ordinary top-level window (which draws, and
    /// cannot be buried by an editor that isn't on that screen anyway); brought
    /// back, it is re-pinned above the editor.
    ///
    /// Both windows are observed — either one can be the one that moves.
    @MainActor
    private static func keepPinnedWhileOnTheSameDisplay(_ card: NSWindow, parent: NSWindow) {
        // `queue: nil` matches WindowCloseCleanup — window notifications are
        // posted on the main thread. No token bookkeeping: these live exactly as
        // long as the tour window, which exists once per app run.
        for observed in [card, parent] {
            let cardMoved = observed === card
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: observed, queue: nil
            ) { [weak card, weak parent] _ in
                MainActor.assumeIsolated {
                    guard let card, let parent else { return }
                    reconcileAttachment(card, parent: parent, mayDetach: cardMoved)
                }
            }
        }
    }

    /// - Parameter mayDetach: only a move of the CARD may break the pin.
    ///
    ///   A child travels with its parent, so dragging the editor across
    ///   displays carries the card along and they are never really apart. But
    ///   the two windows cross the boundary a frame apart, and treating that
    ///   instant as "different displays" detached them mid-drag: the card
    ///   stopped following, then re-pinned once the editor settled, which read
    ///   as the card jumping. A moving editor therefore only ever re-pins a
    ///   card that is already detached — it never detaches one.
    @MainActor
    private static func reconcileAttachment(_ card: NSWindow, parent: NSWindow,
                                            mayDetach: Bool) {
        // A screen of nil means the window is momentarily off every display
        // (mid-drag); leave the relationship alone until it settles.
        guard let cardScreen = card.screen, let parentScreen = parent.screen else { return }
        let together = cardScreen === parentScreen
        // Logged because the failure this guards against is invisible: an
        // unpinned card on the parent's display looks like "the tour got
        // buried", and a still-pinned card on another display looks like "the
        // tour vanished" while AppKit reports it perfectly visible. Transitions
        // only — a per-move trace would fire ~10x/second during any drag.
        if together, card.parent == nil {
            parent.addChildWindow(card, ordered: .above)   // re-pin above the editor
            os_log("re-pinned above the editor (same display again)",
                   log: tourLog, type: .default)
        } else if !together, mayDetach, card.parent === parent {
            parent.removeChildWindow(card)
            card.orderFront(nil)
            os_log("detached — dragged to a display the editor is not on",
                   log: tourLog, type: .default)
        }
    }
}
