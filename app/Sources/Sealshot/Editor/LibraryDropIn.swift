import AppKit
import SwiftUI

/// Which registered sidebar row a drop at `point` belongs to.
///
/// Pure geometry so the boundary cases are unit tests rather than drag
/// sessions. Mirrors `LibraryDragHitPolicy` on the drag side, and needs the
/// same two rects for the same two reasons: `boundsInWindow` says WHICH row,
/// `visibleRectInWindow` says whether the Library is even on screen — Editor
/// and Library are tabs in ONE window, so a row left registered while the
/// Library is hidden must not answer for a drop over the editor canvas.
enum LibraryDropHitPolicy {
    static func accepts(boundsInWindow: NSRect, visibleRectInWindow: NSRect,
                        point: NSPoint, isHidden: Bool) -> Bool {
        guard !isHidden, !visibleRectInWindow.isEmpty else { return false }
        return visibleRectInWindow.contains(point) && boundsInWindow.contains(point)
    }
}

/// Receives in-app capture drags for the Library sidebar (collection rows and
/// ★ Favorites).
///
/// It exists because the drag and the drop had drifted onto different
/// toolkits. The drag became AppKit when multi-file export arrived — SwiftUI
/// cannot drag a multi-selection — and every dragging item is now an
/// `NSFilePromiseProvider`, with the in-app identity (the real `.seal` URLs)
/// riding on the first one. The sidebar's drop stayed a SwiftUI `.onDrop`,
/// which bridges a promise item into a provider for the promised FILE; the
/// custom own-process type does not survive that, so the row never accepted
/// and every drop bounced back.
///
/// Rows cannot host the destination themselves: SwiftUI hosts a `.background`
/// representable as a LEAF, so a per-row backing view is a SIBLING of the row's
/// content, and AppKit resolves a drag destination by walking UP from the view
/// under the pointer. The destination therefore lives on an ancestor — the
/// shell container that is the window's `contentView` — and rows register their
/// window-space frames, exactly as tiles do for the drag-out monitor.
@MainActor
final class LibraryDropMonitor {
    static let shared = LibraryDropMonitor()

    /// Handed the captures resolved from the drag's identity payload.
    typealias Handler = ([URL]) -> Void

    private final class Entry {
        weak var view: NSView?
        var handler: Handler
        init(_ view: NSView, _ handler: @escaping Handler) {
            self.view = view
            self.handler = handler
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ view: NSView, handler: @escaping Handler) {
        entries[ObjectIdentifier(view)] = Entry(view, handler)
    }

    func unregister(_ view: NSView) {
        entries.removeValue(forKey: ObjectIdentifier(view))
    }

    /// The handler for the row under `point` (window coordinates), or nil when
    /// the drop is not over a registered row — which is what lets the drag
    /// bounce everywhere else exactly as it did before.
    func handler(at point: NSPoint) -> Handler? {
        for (key, entry) in entries {
            guard let view = entry.view else {
                entries.removeValue(forKey: key)   // row went away
                continue
            }
            let bounds = view.convert(view.bounds, to: nil)
            let visible = view.convert(view.visibleRect, to: nil)
            if LibraryDropHitPolicy.accepts(boundsInWindow: bounds,
                                            visibleRectInWindow: visible,
                                            point: point, isHidden: view.isHiddenOrHasHiddenAncestor) {
                return entry.handler
            }
        }
        return nil
    }

    /// The row under `point`, for highlighting while the drag hovers.
    func rowView(at point: NSPoint) -> NSView? {
        for (_, entry) in entries {
            guard let view = entry.view else { continue }
            let bounds = view.convert(view.bounds, to: nil)
            let visible = view.convert(view.visibleRect, to: nil)
            if LibraryDropHitPolicy.accepts(boundsInWindow: bounds,
                                            visibleRectInWindow: visible,
                                            point: point, isHidden: view.isHiddenOrHasHiddenAncestor) {
                return view
            }
        }
        return nil
    }
}

/// The window's content view, doubling as the drag destination for in-app
/// capture drags. Registered ONLY for the capture-list type, so it is inert for
/// every other drag — Finder file drops still reach the grid, the strip and the
/// canvas, which are registered for `public.file-url` deeper in the hierarchy
/// and win the destination search.
final class ShellDropContainerView: NSView {

    /// Highlighted row, so a multi-item drag shows where it will land.
    private weak var highlighted: LibraryDropTargetView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            NSPasteboard.PasteboardType(CaptureDragPayload.captureListTypeIdentifier),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func point(for sender: NSDraggingInfo) -> NSPoint {
        convert(sender.draggingLocation, to: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = point(for: sender)
        let row = LibraryDropMonitor.shared.rowView(at: location) as? LibraryDropTargetView
        setHighlight(row)
        return row == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlight(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setHighlight(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlight(nil)
        guard let handler = LibraryDropMonitor.shared.handler(at: point(for: sender)),
              let data = sender.draggingPasteboard.data(
                forType: NSPasteboard.PasteboardType(CaptureDragPayload.captureListTypeIdentifier))
        else { return false }
        let urls = CaptureDragPayload.captureURLs(fromListData: data)
        guard !urls.isEmpty else { return false }
        handler(urls)
        return true
    }

    private func setHighlight(_ row: LibraryDropTargetView?) {
        guard highlighted !== row else { return }
        highlighted?.isDropTargeted = false
        row?.isDropTargeted = true
        highlighted = row
    }
}

/// Per-row registrant: a hit-test-transparent leaf that contributes only its
/// frame (so the monitor can locate the row) and draws the drop highlight.
/// It never intercepts mouse events, so selecting, renaming and the row's
/// context menu all keep working.
final class LibraryDropTargetView: NSView {

    var handler: LibraryDropMonitor.Handler = { _ in }

    var isDropTargeted = false {
        didSet { if isDropTargeted != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            LibraryDropMonitor.shared.unregister(self)
            isDropTargeted = false
        } else {
            LibraryDropMonitor.shared.register(self) { [weak self] urls in
                self?.handler(urls)
            }
        }
    }

    deinit {
        MainActor.assumeIsolated { LibraryDropMonitor.shared.unregister(self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isDropTargeted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 6, yRadius: 6)
        Theme.accentColor.withAlphaComponent(0.18).setFill()
        path.fill()
        Theme.accentColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

private struct LibraryDropRegisterView: NSViewRepresentable {
    let handler: LibraryDropMonitor.Handler

    func makeNSView(context: Context) -> LibraryDropTargetView {
        let view = LibraryDropTargetView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: LibraryDropTargetView, context: Context) {
        nsView.handler = handler
    }
}

extension View {
    /// Accept in-app capture drags on this sidebar row. The row keeps its own
    /// SwiftUI behaviour; this only contributes a frame and a highlight.
    func libraryDropIn(_ handler: @escaping LibraryDropMonitor.Handler) -> some View {
        background(LibraryDropRegisterView(handler: handler))
    }
}
