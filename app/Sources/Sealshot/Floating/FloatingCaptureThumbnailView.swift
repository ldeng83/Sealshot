import AppKit

/// A capture thumbnail on the floating panel that can be dragged out to Finder
/// or another app, exactly as the editor's recent strip can.
///
/// The export path is the strip's own — `CaptureDragPayload` promises through a
/// `DragExportSession` — so the file is written once, after the drop, and an
/// abandoned drag leaves no decrypted copy in the temp folder.
///
/// Dragging a tile always starts a FILE drag once it passes the threshold; it
/// never moves the panel. The window drag stays available from the grip, the
/// background and the gaps in the button row.
final class FloatingCaptureThumbnailView: NSImageView, NSDraggingSource {

    /// The editor strip's threshold, so a tile feels the same in both places.
    static let dragThreshold: CGFloat = 4

    var url: URL?
    var displayName: String = ""
    var isVideo = false {
        didSet { playBadge.isHidden = !isVideo }
    }

    /// A recording is indistinguishable from an image at 64pt without this —
    /// same `.seal` wrapper, often the same first-frame pixels. Centered play
    /// glyph, the editor strip's affordance.
    private lazy var playBadge: NSImageView = {
        let badge = NSImageView()
        badge.image = NSImage(systemSymbolName: "play.circle.fill",
                              accessibilityDescription: "Video")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.shadowColor = NSColor.black.cgColor
        badge.layer?.shadowOpacity = 0.6
        badge.layer?.shadowRadius = 2
        badge.layer?.shadowOffset = .zero
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return badge
    }()

    var playBadgeVisibleForTesting: Bool { isVideo && !playBadge.isHidden }

    private var mouseDownPoint: NSPoint?

    /// Hand a promise provider's delegate to something longer-lived. AppKit
    /// holds it WEAKLY, and without a strong reference the drop dies silently —
    /// the receiver never even gets as far as asking for the filename. The tile
    /// cannot hold it itself: `FloatingCaptureController.renderThumbnails()`
    /// destroys and recreates every tile on each landed capture and whenever
    /// the editor opens, either of which can happen mid-drag. Set by the
    /// controller, which owns the list.
    var retainDragLifeline: ((AnyObject) -> Void)?

    /// Whether a drag could start right now — a capture is set and it is
    /// exportable. Gates on the same check the editor strip uses.
    @MainActor
    var canStartDragForTesting: Bool {
        guard let url else { return false }
        return CaptureDragPayload.canExport(url)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let url else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard exceedsDragThreshold(from: start, to: current) else { return }
        mouseDownPoint = nil
        beginFileDrag(url: url, event: event)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    private func exceedsDragThreshold(from start: NSPoint, to current: NSPoint) -> Bool {
        let dx = current.x - start.x
        let dy = current.y - start.y
        return dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold
    }

    func exceedsDragThresholdForTesting(from start: NSPoint, to current: NSPoint) -> Bool {
        exceedsDragThreshold(from: start, to: current)
    }

    /// What a tile hands to the pasteboard for one capture.
    enum WriterChoice: Equatable {
        /// A real file, rendered before the gesture goes anywhere.
        case eagerFile(URL)
        /// A file promise, written after the drop.
        case promise
    }

    /// The editor strip's writer choice, made the same way and for the same
    /// reason: a plain file URL works where a promise doesn't — Terminal path
    /// insert, canvas insert, and anything that reads only public.file-url — so
    /// it is the default. Fall back to a promise only when an eager render
    /// would block the gesture (`requiresPromise`: an encrypted video payload,
    /// gigabytes to decrypt) or when the render unexpectedly fails.
    ///
    /// A panel drag is always a SINGLE item, so the strip's multi-select
    /// homogeneity rule (never mix promises with plain URLs) cannot arise here.
    @MainActor
    static func writerChoice(for source: CaptureDragPayload.Source) -> WriterChoice {
        guard !CaptureDragPayload.requiresPromise(source),
              let eagerURL = CaptureDragPayload.eagerFileURL(for: source)
        else { return .promise }
        return .eagerFile(eagerURL)
    }

    @MainActor
    private func beginFileDrag(url: URL, event: NSEvent) {
        guard CaptureDragPayload.canExport(url) else {
            FloatingDragDiag.note("drag refused before start: canExport=false "
                                  + "for \(url.lastPathComponent)")
            return
        }
        let source = CaptureDragPayload.Source(url: url,
                                               displayName: displayName,
                                               isVideo: isVideo)
        let choice = Self.writerChoice(for: source)
        FloatingDragDiag.note("drag start: \(url.lastPathComponent) isVideo=\(isVideo) "
                              + "requiresPromise=\(CaptureDragPayload.requiresPromise(source)) "
                              + "writer=\(choice == .promise ? "PROMISE" : "eager file URL")")

        let writer: NSPasteboardWriting
        switch Self.writerChoice(for: source) {
        case .eagerFile(let eagerURL):
            // Finder COPIES it rather than aliasing it: the out-of-app
            // operation mask below is `.copy` only.
            writer = eagerURL as NSURL
        case .promise:
            // `host: nil` — deliberately NO progress sheet. The only window
            // available to host one is the panel itself, a borderless
            // `.nonactivatingPanel` that can never become key (undefined sheet
            // presentation) and that `hideForCapture()` and the ✕ button order
            // out mid-export, taking the sheet with it. The editor is no better
            // a host: it is frequently not open at all when the panel is in
            // use, so the same drag would show progress sometimes and not
            // others. `DragExportSession.ensureBegun` guards on a nil host, so
            // the export still runs and still reports through the promise.
            let session = DragExportSession(totalItems: 1, host: nil, immediate: false)
            let promise = CaptureDragPayload.promiseItem(for: source, session: session)
            retainDragLifeline?(promise.retainer)
            writer = promise.provider
        }

        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// `.copy` out of the app, matching the strip: it stops Finder resolving a
    /// dropped capture as an alias rather than copying it.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation { .copy }

    /// Modifiers must not change what a drop DOES. macOS reserves ⌃ during a
    /// drag to mean "make a link", filtering the source mask down to `.link`
    /// at the drop — and the out-of-app mask here is deliberately `.copy`
    /// only, so a ⌃-drop resolved to NO operation and Finder bounced the
    /// drag. ⌃ is Sealshot's hide-the-window key, held through the drop by
    /// design: the drag hint itself tells the user to press it.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    /// The verdict: operation 0 (none) means the receiver refused the drag —
    /// the visible bounce. Anything else means it was accepted.
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        FloatingDragDiag.note("drag ended: operation=\(operation.rawValue)"
                              + (operation.isEmpty ? " (REFUSED — bounce)" : " (accepted)"))
    }
}
