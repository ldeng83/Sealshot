import SwiftUI
import AppKit
import AVKit

/// ⌘+scroll over the preview resizes the whole panel (not the image inside it).
/// These NSView subclasses capture ⌘+scroll and forward the wheel delta to the
/// overlay via `onCommandScroll`; plain scroll falls through. Using the wheel +
/// ⌘ modifier matches the editor canvas's zoom gesture.
final class QuickLookScrollView: NSScrollView {
    var onCommandScroll: ((_ deltaY: CGFloat, _ precise: Bool) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onCommandScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            return
        }
        super.scrollWheel(with: event)
    }
}

final class QuickLookPlayerView: AVPlayerView {
    var onCommandScroll: ((_ deltaY: CGFloat, _ precise: Bool) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onCommandScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            return
        }
        super.scrollWheel(with: event)
    }
}

/// Full-res image that fits its frame. The panel frame is what grows/shrinks on
/// ⌘+scroll (handled by the overlay); the image always fits it, so it stays
/// sharp as the panel enlarges (backed by a downsampled-to-4096 NSImage).
struct QuickLookImageView: NSViewRepresentable {
    let image: NSImage
    var onCommandScroll: ((_ deltaY: CGFloat, _ precise: Bool) -> Void)?

    func makeNSView(context: Context) -> QuickLookScrollView {
        let scroll = QuickLookScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.onCommandScroll = onCommandScroll
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.image = image
        iv.autoresizingMask = [.width, .height]
        iv.frame = scroll.bounds
        scroll.documentView = iv
        return scroll
    }

    func updateNSView(_ scroll: QuickLookScrollView, context: Context) {
        scroll.onCommandScroll = onCommandScroll
        if let iv = scroll.documentView as? NSImageView, iv.image !== image {
            iv.image = image
        }
    }
}

/// Playable video via an AVPlayerView. The AVPlayer is built + owned by the
/// loader (Task 5) so the decrypt stream stays alive; this view only displays it.
/// ⌘+scroll is forwarded to resize the panel (same as the image path).
struct QuickLookVideoView: NSViewRepresentable {
    let player: AVPlayer
    var onCommandScroll: ((_ deltaY: CGFloat, _ precise: Bool) -> Void)?

    func makeNSView(context: Context) -> QuickLookPlayerView {
        let v = QuickLookPlayerView()
        v.player = player
        // `.floating` shows the transport controls in a HUD bar on hover WITHOUT
        // darkening the whole video the way `.inline` does.
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        // See CanvasVideoPlayerView: Apple's paused-frame Live Text takes over
        // the right-click, and this preview has its own menu to offer.
        if #available(macOS 13.0, *) { v.allowsVideoFrameAnalysis = false }
        v.onCommandScroll = onCommandScroll
        return v
    }

    func updateNSView(_ v: QuickLookPlayerView, context: Context) {
        v.onCommandScroll = onCommandScroll
        if v.player !== player { v.player = player }
    }
}
