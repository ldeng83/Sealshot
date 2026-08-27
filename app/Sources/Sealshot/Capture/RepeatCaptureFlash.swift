import AppKit

/// A brief outline of the area a repeat capture just took.
///
/// Repeating an area has no overlay and no selection, which is the point — and
/// also means that without this, nothing on screen distinguishes "captured the
/// right box" from "captured something else" or "did nothing at all". The
/// flash is the receipt. It appears AFTER the pixels are taken, so it can
/// never appear in them.
///
/// Click-through and non-activating throughout: this is feedback, not a
/// surface. It must never take a click away from whatever the user is
/// documenting, and it must not pull focus from the app they are working in.
@MainActor
enum RepeatCaptureFlash {
    static let duration: TimeInterval = 0.35
    static let lineWidth: CGFloat = 3

    /// Retained for as long as it is on screen; a panel with no owner is
    /// released mid-fade and flickers out early.
    private static var current: NSPanel?

    static func show(_ region: SelectedRegion) {
        show(rect: region.globalRect, duration: duration)
    }

    static func show(rect: CGRect, duration: TimeInterval) {
        current?.orderOut(nil)
        let panel = NSPanel(contentRect: rect.insetBy(dx: -lineWidth, dy: -lineWidth),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        // Visible over full-screen spaces too — a fixed dashboard region being
        // watched is quite often in one.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FlashView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.orderFrontRegardless()
        current = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                // Only clear the shared slot if this flash is still the current
                // one — a second capture during the fade owns it now.
                if current === panel { current = nil }
            }
        }
    }

    /// Test hook: whether a flash is on screen, and where.
    static var visibleFrameForTesting: CGRect? {
        guard let current, current.isVisible else { return nil }
        return current.frame
    }
    static func dismissForTesting() {
        current?.orderOut(nil)
        current = nil
    }

    private final class FlashView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let inset = RepeatCaptureFlash.lineWidth / 2
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            path.lineWidth = RepeatCaptureFlash.lineWidth
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }
}
