import AppKit
import SwiftUI

/// Whether a mouse-down should arm a Library tile's file drag.
///
/// Pure geometry, and it needs BOTH rects because they answer different
/// questions — measured, not assumed (see the notes below):
///
/// - `boundsInWindow` — WHICH tile. It is the registrant's own frame, so
///   exactly one tile matches a click, and a click in the gaps between tiles
///   matches none (which is what leaves the marquee free to start there).
/// - `visibleRectInWindow` — WHETHER THE LIBRARY IS ON SCREEN. For these
///   SwiftUI-hosted registrants it reports the enclosing grid clip, IDENTICAL
///   for every tile — useless for identifying one, but exactly right for the
///   tab question: it collapses to empty when the Library isn't showing.
///
/// Both are required. Editor and Library are tabs in ONE window and this
/// monitor is app-wide, so matching bounds alone lets a tile left registered
/// while the Library is off-screen answer for a click on the editor canvas and
/// turn rectangle drawing into a drag-out. Matching the visible rect alone
/// matches EVERY tile at once, which arms an arbitrary one (dragging the wrong
/// capture) and swallows marquee drags in empty space.
///
/// This replaced a view-hierarchy test (`hit.isDescendant(of:
/// registrant.superview)`) that SwiftUI silently invalidated: it hosts a
/// `.background` representable as a LEAF, so a tile's content is a SIBLING of
/// its registrant, never a descendant. That check could never pass, and
/// Library drag-out was dead in both grid and list.
enum LibraryDragHitPolicy {
    static func shouldArm(boundsInWindow: NSRect, visibleRectInWindow: NSRect,
                          point: NSPoint, isHidden: Bool, sameWindow: Bool) -> Bool {
        guard sameWindow, !isHidden, !visibleRectInWindow.isEmpty else { return false }
        // Library on screen (clip non-empty and covering the click) AND this
        // specific tile under the pointer.
        return visibleRectInWindow.contains(point) && boundsInWindow.contains(point)
    }
}

/// Multi-file drag-out for the SwiftUI Library grid/list. SwiftUI can't drag a
/// multi-selection, and the DragGesture→NSApp.currentEvent bridge is unreliable,
/// so instead a single app-local `NSEvent` monitor watches left-mouse events and
/// starts an `NSDraggingSession` when a real drag begins over a tile. The monitor
/// NEVER consumes events, so SwiftUI keeps taps, double-clicks, context menus,
/// and the marquee; each tile just registers a hit-test-transparent backing view
/// (so it never blocks clicks) plus a closure that builds the drag items.
@MainActor
final class LibraryDragMonitor {
    static let shared = LibraryDragMonitor()

    typealias Build = () -> (items: [NSDraggingItem], retainers: [AnyObject])?

    private final class Entry {
        weak var view: NSView?
        var build: Build
        init(_ view: NSView, _ build: @escaping Build) { self.view = view; self.build = build }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?

    // In-flight gesture bookkeeping.
    private weak var downView: NSView?
    private var downBuild: Build?
    private var downPoint: NSPoint = .zero
    // Lifelines for the current drag (weak promise delegates + the drag source),
    // replaced on the NEXT drag — the receiver resolves promises AFTER the drag
    // ends, so releasing earlier would kill the write mid-flight.
    private var retainers: [AnyObject] = []
    private var source: LibraryDragSource?

    func register(_ view: NSView, build: @escaping Build) {
        entries[ObjectIdentifier(view)] = Entry(view, build)
        ensureMonitor()
    }

    func unregister(_ view: NSView) {
        entries[ObjectIdentifier(view)] = nil
        entries = entries.filter { $0.value.view != nil }   // drop dead weak refs
    }

    private func ensureMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { event in
            let consumed = MainActor.assumeIsolated { LibraryDragMonitor.shared.handle(event) }
            // Swallow ONLY the drag-starting event so it isn't also dispatched to
            // SwiftUI (double-dispatch); pass everything else through so taps /
            // double-clicks / context menus / marquee keep working.
            return consumed ? nil : event
        }
    }

    /// Returns true when it consumed the event (a drag was started).
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            downView = nil; downBuild = nil
            guard let window = event.window else { return false }
            let p = event.locationInWindow
            for entry in entries.values {
                guard let v = entry.view,
                      LibraryDragHitPolicy.shouldArm(
                        boundsInWindow: v.convert(v.bounds, to: nil),
                        visibleRectInWindow: v.convert(v.visibleRect, to: nil),
                        point: p,
                        isHidden: v.isHiddenOrHasHiddenAncestor,
                        sameWindow: v.window === window)
                else { continue }
                downView = v; downBuild = entry.build; downPoint = p
                break
            }
            return false
        case .leftMouseDragged:
            guard let v = downView, let build = downBuild else { return false }
            let p = event.locationInWindow
            guard hypot(p.x - downPoint.x, p.y - downPoint.y) >= 8 else { return false }
            downView = nil; downBuild = nil   // one session per gesture
            guard let built = build(), !built.items.isEmpty else { return false }
            retainers = built.retainers
            let source = LibraryDragSource(window: v.window)
            self.source = source
            v.beginDraggingSession(with: built.items, event: event, source: source)
            return true
        case .leftMouseUp:
            downView = nil; downBuild = nil
            return false
        default:
            return false
        }
    }
}

/// Drag source for a Library drag. The identity type is own-process: Finder
/// ignores it, the sidebar reads it.
final class LibraryDragSource: NSObject, NSDraggingSource {

    /// WEAK. This source outlives nothing, but a drag source holding a window
    /// strongly would keep a closed editor alive for the life of the drag.
    private weak var peekWindow: NSWindow?

    init(window: NSWindow?) {
        self.peekWindow = window
        super.init()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Out of app: COPY only. A single-item drag now carries a plain file
        // URL (so Terminal and the canvas work), and offering `.generic` there
        // lets Finder resolve that URL as an ALIAS — a broken ~1KB export
        // instead of the file. The recent strip restricts it for the same
        // reason. Within-app drops keep the full set.
        context == .outsideApplication ? .copy : [.copy, .generic]
    }

    /// Modifiers must not change what a drop DOES. macOS reserves ⌃ during a
    /// drag to mean "make a link", filtering the source mask down to `.link`
    /// at the drop — and the out-of-app mask here is deliberately `.copy`
    /// only, so a ⌃-drop resolved to NO operation and Finder bounced the
    /// drag. ⌃ is Sealshot's hide-the-window key, held through the drop by
    /// design: the drag hint itself tells the user to press it.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        DragPeekController.shared.begin(hiding: peekWindow)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        DragPeekController.shared.end()
    }
}

/// Hit-test-transparent backing view: it's laid out at the tile's frame (so the
/// monitor can locate the tile) but never intercepts mouse events, so SwiftUI's
/// tap / double-tap / context-menu / marquee all keep working.
final class DragPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - ⌘+scroll tile resize

/// App-local `scrollWheel` monitor that turns ⌘+scroll OVER THE GRID into a
/// tile-size change. It's gated by a hit-test against a registered grid-backing
/// view (like the drag monitor), so ⌘+scroll elsewhere — notably the editor
/// canvas's own zoom — is untouched. Only ⌘+scroll is consumed; a plain scroll
/// passes through so the grid still scrolls normally.
@MainActor
final class LibraryTileZoomMonitor {
    static let shared = LibraryTileZoomMonitor()

    typealias OnScroll = (_ deltaY: CGFloat, _ precise: Bool) -> Void

    private final class Entry {
        weak var view: NSView?
        var onScroll: OnScroll
        init(_ view: NSView, _ onScroll: @escaping OnScroll) { self.view = view; self.onScroll = onScroll }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?

    func register(_ view: NSView, onScroll: @escaping OnScroll) {
        entries[ObjectIdentifier(view)] = Entry(view, onScroll)
        ensureMonitor()
    }
    func unregister(_ view: NSView) {
        entries[ObjectIdentifier(view)] = nil
        entries = entries.filter { $0.value.view != nil }
    }

    private func ensureMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            let consumed = MainActor.assumeIsolated { LibraryTileZoomMonitor.shared.handle(event) }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let window = event.window else { return false }
        let p = event.locationInWindow
        for entry in entries.values {
            // Match the VISIBLE grid area (visibleRect, not full bounds): when the
            // Library tab isn't shown the grid's clip collapses to an empty
            // visibleRect, so ⌘+scroll over the editor canvas isn't captured.
            guard let v = entry.view, v.window === window,
                  !v.isHiddenOrHasHiddenAncestor,
                  v.convert(v.visibleRect, to: nil).contains(p)
            else { continue }
            entry.onScroll(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            return true   // consume ⌘+scroll so the grid doesn't also scroll
        }
        return false
    }
}

private struct TileZoomRegisterView: NSViewRepresentable {
    let onScroll: LibraryTileZoomMonitor.OnScroll
    func makeNSView(context: Context) -> DragPassthroughView {
        let v = DragPassthroughView()
        LibraryTileZoomMonitor.shared.register(v, onScroll: onScroll)
        return v
    }
    func updateNSView(_ nsView: DragPassthroughView, context: Context) {
        LibraryTileZoomMonitor.shared.register(nsView, onScroll: onScroll)
    }
    static func dismantleNSView(_ nsView: DragPassthroughView, coordinator: ()) {
        LibraryTileZoomMonitor.shared.unregister(nsView)
    }
}

extension View {
    /// ⌘+scroll over this view (the grid) resizes Library tiles via `onScroll`.
    func libraryTileZoom(onScroll: @escaping LibraryTileZoomMonitor.OnScroll) -> some View {
        background(TileZoomRegisterView(onScroll: onScroll))
    }
}

private struct LibraryDragRegisterView: NSViewRepresentable {
    let build: LibraryDragMonitor.Build
    func makeNSView(context: Context) -> DragPassthroughView {
        let v = DragPassthroughView()
        LibraryDragMonitor.shared.register(v, build: build)
        return v
    }
    func updateNSView(_ nsView: DragPassthroughView, context: Context) {
        // Refresh the closure so it captures the latest item/selection state.
        LibraryDragMonitor.shared.register(nsView, build: build)
    }
    static func dismantleNSView(_ nsView: DragPassthroughView, coordinator: ()) {
        LibraryDragMonitor.shared.unregister(nsView)
    }
}

extension View {
    /// Enable AppKit multi-file drag-out from a Library tile. `build` runs at drag
    /// start and returns one file item per selected capture (+ a hidden identity
    /// item). Taps / menus stay in SwiftUI.
    func libraryDragOut(build: @escaping LibraryDragMonitor.Build) -> some View {
        background(LibraryDragRegisterView(build: build))
    }
}
