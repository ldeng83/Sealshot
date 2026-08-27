import SwiftUI
import AppKit

/// A tooltip that actually appears.
///
/// SwiftUI's `.help()` did not surface on the Library's sidebar buttons, while
/// the editor's AppKit surfaces (`ActiveToolPillView.tooltipText`) show theirs
/// immediately — the app registers `NSInitialToolTipDelay = 1`, which AppKit
/// reads when it sets up tooltip tracking for a view's `toolTip`.
///
/// So this bridges to that same mechanism: a zero-size probe is placed behind
/// the control, and the tooltip is set on the SwiftUI-managed `NSView` that
/// hosts it. Hit testing is untouched — the probe never intercepts a click,
/// because the tooltip lives on the ancestor that already handles the mouse.
private struct TooltipProbe: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The probe's own superview is the container SwiftUI built for this
        // control; setting the tooltip there covers the control's whole area.
        // Deferred because the view is not in a hierarchy on the first pass.
        DispatchQueue.main.async {
            (view.superview ?? view).toolTip = text
        }
    }
}

extension View {
    /// `.help()` that reliably shows, with the app's immediate delay.
    func appKitTooltip(_ text: String) -> some View {
        background(TooltipProbe(text: text))
    }
}
