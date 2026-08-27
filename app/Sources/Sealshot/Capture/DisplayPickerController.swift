import AppKit
import ScreenCaptureKit

/// The result of the monitor picker: the chosen display + (for image capture) the
/// frozen snapshot to capture from.
struct DisplayPickResult {
    let choice: DisplayChoice
    let screen: NSScreen
    let reference: CGRect
    /// The frozen capture for `choice` (the display's snapshot, or the stitched
    /// All-Displays image). Present only when `freeze: true` (image capture); nil
    /// for recording, which streams the chosen display live.
    let frozenImage: CGImage?
}

/// A click-a-monitor overlay. With `freeze: true` (image capture) it first snapshots
/// every display and shows those FROZEN frames — just like the area-selection
/// capture — so the screen appears frozen while you pick, and the capture comes
/// from that snapshot. A plain click picks that screen; ⌘-click picks All Displays
/// (image only), hinted by a tip that follows the cursor; Esc / right-click cancels.
@MainActor
final class DisplayPickerController {

    private var panels: [WindowPickerPanel] = []
    private var continuation: CheckedContinuation<DisplayPickResult?, Never>?
    /// True while the click-a-monitor overlay is up (the coordinator's busy gate).
    var isRunning: Bool { continuation != nil }
    private var keyMonitor: Any?
    private var screens: [NSScreen] = []
    private var frozen: [Int: CGImage] = [:]

    func pick(allowAllDisplays: Bool, freeze: Bool) async -> DisplayPickResult? {
        guard continuation == nil else { return nil }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        self.screens = screens
        if freeze { self.frozen = await Self.snapshotDisplays(screens) }
        return await withCheckedContinuation { (cont: CheckedContinuation<DisplayPickResult?, Never>) in
            self.continuation = cont
            self.showOverlays(allowAllDisplays: allowAllDisplays)
        }
    }

    /// Snapshot every display (Sealshot's own windows excluded), keyed by index.
    private static func snapshotDisplays(_ screens: [NSScreen]) async -> [Int: CGImage] {
        guard let content = try? await SCShareableContent.current else { return [:] }
        var out: [Int: CGImage] = [:]
        for (i, screen) in screens.enumerated() {
            guard let id = DisplayResolver.displayID(for: screen),
                  let sc = DisplayResolver.match(displayID: id, in: content.displays) else { continue }
            let filter = SelfExcludingContentFilter.display(sc, in: content)
            if let img = try? await ScreenCaptureCore.captureImage(filter: filter, sourceRectPoints: nil) {
                out[i] = img
            }
        }
        return out
    }

    private func showOverlays(allowAllDisplays: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        for (index, screen) in screens.enumerated() {
            let panel = WindowPickerPanel(screen: screen)
            let px = Int((screen.frame.width * screen.backingScaleFactor).rounded())
            let py = Int((screen.frame.height * screen.backingScaleFactor).rounded())
            let view = DisplayPickerView(
                title: screen.localizedName,
                subtitle: "Display \(index + 1) · \(px)×\(py)",
                frozenImage: frozen[index],
                allowAllDisplays: allowAllDisplays,
                frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onPickThis = { [weak self] in self?.complete(.display(index: index)) }
            view.onPickAll = { [weak self] in self?.complete(.allDisplays) }
            view.onCancel = { [weak self] in self?.complete(nil) }
            panel.contentView = view
            panel.initialFirstResponder = view
            panel.acceptsMouseMovedEvents = true
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        panels.first?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {   // Esc
                Task { @MainActor in self?.complete(nil) }
                return nil
            }
            return event
        }
    }

    private func complete(_ choice: DisplayChoice?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        for p in panels { p.close() }
        panels.removeAll()
        cont.resume(returning: choice.flatMap(makeResult))
    }

    private func makeResult(_ choice: DisplayChoice) -> DisplayPickResult? {
        switch choice {
        case .display(let i):
            guard screens.indices.contains(i) else { return nil }
            return DisplayPickResult(choice: choice, screen: screens[i],
                                     reference: screens[i].frame, frozenImage: frozen[i])
        case .allDisplays:
            // Uniform output scale (highest display DPI); the stitcher lays the
            // tiles out in point-space so mixed-scale displays stay correct.
            let scale = screens.map(\.backingScaleFactor).max() ?? 2
            var tiles: [(pointFrame: CGRect, image: CGImage)] = []
            for (i, s) in screens.enumerated() {
                guard let img = frozen[i] else { continue }
                tiles.append((s.frame, img))
            }
            let reference = screens.reduce(CGRect.null) { $0.union($1.frame) }
            return DisplayPickResult(choice: choice, screen: NSScreen.main ?? screens[0],
                                     reference: reference,
                                     frozenImage: MultiDisplayStitcher.stitch(tiles, outputScale: scale))
        }
    }
}

/// The per-screen overlay: shows the frozen snapshot (when provided), dimmed; a
/// plain click picks this screen; ⌘-click picks all (when allowed), with a cursor
/// tip; right-click / Esc cancels.
@MainActor
private final class DisplayPickerView: NSView {
    var onPickThis: (() -> Void)?
    var onPickAll: (() -> Void)?
    var onCancel: (() -> Void)?

    private let allowAll: Bool
    private let frozen: NSImage?
    private var hovering = false
    private var tracking: NSTrackingArea?
    private let tip = DisplayPickerTip(text: "⌘-click to capture all displays")

    init(title: String, subtitle: String, frozenImage: CGImage?, allowAllDisplays: Bool, frame: NSRect) {
        self.allowAll = allowAllDisplays
        self.frozen = frozenImage.map { NSImage(cgImage: $0, size: frame.size) }
        super.init(frame: frame)
        wantsLayer = true

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        name.textColor = .white
        name.alignment = .center
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 14)
        sub.textColor = NSColor.white.withAlphaComponent(0.8)
        sub.alignment = .center
        let hint = NSTextField(labelWithString: "Click this screen to capture it")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = NSColor.white.withAlphaComponent(0.6)
        hint.alignment = .center

        let stack = NSStackView(views: [name, sub, hint])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if allowAll {
            tip.isHidden = true
            addSubview(tip)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if allowAll { tip.isHidden = false }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        tip.isHidden = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard allowAll else { return }
        let p = convert(event.locationInWindow, from: nil)
        tip.isHidden = false
        // Below-right of the cursor, matching the crosshair badge's 18pt offset.
        tip.setFrameOrigin(NSPoint(x: p.x + 18, y: p.y - tip.frame.height - 18))
    }

    override func draw(_ dirtyRect: NSRect) {
        // The frozen snapshot first (a layer-backed view's draw() overwrites
        // layer.contents, so the freeze must be drawn here), then the dim on top.
        frozen?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSColor.black.withAlphaComponent(hovering ? 0.20 : 0.45).setFill()
        bounds.fill()
        if hovering {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            border.lineWidth = 8
            border.stroke()
        }
    }

    // Only the first screen's panel is made key; the others are just ordered
    // front. Without this, a click on a non-key screen's panel is consumed just
    // to make that window key (never delivered as a down/up to this view), so
    // the user had to click twice on every screen except the key one. Returning
    // true delivers the first click's full down/up — matching the sibling
    // overlay views (SelectionView, UnifiedSelectionView, WindowHighlightView).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if allowAll, event.modifierFlags.contains(.command) { onPickAll?() }
        else { onPickThis?() }
    }

    override func rightMouseUp(with event: NSEvent) { onCancel?() }
}

/// A badge that follows the cursor inside the picker overlay. Styled to match the
/// area-selection crosshair badge (`CaptureCrosshair`): black 0.78 background,
/// 6pt corners, white hint text — for visual consistency across capture overlays.
@MainActor
private final class DisplayPickerTip: NSView {
    init(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.translatesAutoresizingMaskIntoConstraints = false
        let size = label.intrinsicContentSize
        let padX: CGFloat = 10, padY: CGFloat = 7
        super.init(frame: NSRect(x: 0, y: 0, width: size.width + padX * 2, height: size.height + padY * 2))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 6
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never intercept clicks
}
