import AppKit
import UniformTypeIdentifiers

/// Which folder the strip is viewing and which actions its thumbnails
/// support. `.recent` shows the save folder with a delete button;
/// `.deleted` shows the Deleted/ subfolder with a restore button.
enum StripMode {
    case recent
    case deleted
}

/// Horizontal scroll strip showing thumbnails of recent captures from
/// `config.saveFolder`. Clicking a thumbnail fires `onSelect` with the
/// file URL. The strip loads from the shared library index and refreshes
/// in place.
final class RecentStripView: NSView {

    let onSelect: (URL) -> Void
    /// Thumbnail image height. Injected at build time (persisted by the
    /// controller) and updated live while the user drags the resize handle.
    private var thumbHeight: CGFloat
    /// Height reserved below the image for the display-name label (caption font).
    private let labelHeight: CGFloat = 18
    /// Fixed thumbnail aspect (width ÷ height). Every tile is the same
    /// 4:3 landscape box; captures are center-cropped to fill it.
    private let thumbAspect: CGFloat = 4.0 / 3.0
    private let thumbSpacing: CGFloat = 8
    private var folder: URL
    private let daysBack: Int
    let mode: StripMode
    var onDelete: ((URL) -> Void)?
    var onRestore: ((URL) -> Void)?
    /// Reveal + highlight this capture in the Library tab. Set by the
    /// controller; fired by the thumbnail's "Show in Library" menu item.
    var onShowInLibrary: ((URL) -> Void)?

    /// Bulk action callbacks. Set by the controller in makeRecentStrip /
    /// makeDeletedStrip. Fired by the right-click context menu when the
    /// clicked thumbnail is in `selectedURLs`.
    var onBulkDelete: (([URL]) -> Void)?
    var onBulkRestore: (([URL]) -> Void)?

    /// Permanent-delete callbacks (Deleted tab only). Set by the controller
    /// in makeDeletedStrip. Fire only after the controller has shown its
    /// confirmation alert — the strip does NOT confirm on its own.
    var onPermanentDelete: ((URL) -> Void)?
    var onBulkPermanentDelete: (([URL]) -> Void)?

    /// Fired on the main actor after `apply(_:)` finishes mutating tiles —
    /// i.e. whenever content (re)lands asynchronously. The controller uses
    /// this to re-mirror unsaved edits onto the open file's fresh tile.
    var onContentApplied: (() -> Void)?

    /// Open a video `.seal` in the canvas (videos can't be edited). Set by the
    /// controller. `autoPlay` starts playback immediately (the play-badge click);
    /// otherwise the video opens paused on its first frame.
    var onPlayVideo: ((_ url: URL, _ autoPlay: Bool) -> Void)?

    /// Set of video tile URLs currently shown, so a plain click
    /// can play (not open in editor). Rebuilt in `apply`.
    private var videoItems: [URL: Bool] = [:]

    /// URLs currently in the multi-selection set. Mutated by handlePlainClick,
    /// handleCmdClick, handleShiftClick. Cleared by clearSelection. The
    /// "currently open" URL (selectedURL setter) is conceptually distinct
    /// and tracked separately.
    private(set) var selectedURLs: Set<URL> = [] {
        didSet { publishExportSelection() }
    }

    /// Most-recent plain-click target — used as the anchor for ⇧-click
    /// range selection. Defaults to `selectedURL` (the open file) if no
    /// plain-click has happened yet.
    private var anchorURL: URL?

    /// Selection a ⇧-click extension must preserve — the block that existed
    /// before the shift sequence (a marquee, a ⌘-click set, or a plain click).
    /// Every selection-defining action refreshes it; ⇧-click unions onto it but
    /// leaves it fixed, so successive ⇧-clicks can still shrink. This is what
    /// lets a ⇧-click after a marquee continue the block instead of replacing
    /// it — mirrors the Library grid's `shiftSelectionFloor`.
    private var shiftFloor: Set<URL> = []

    var hasSelection: Bool { !selectedURLs.isEmpty }

    private weak var stack: NSStackView?
    /// "No captures here yet." — shown only while the strip has no tiles.
    private weak var emptyLabel: NSTextField?
    private weak var marqueeContainer: MarqueeView?

    /// URL whose thumbnail should render in the "selected" state. Set by
    /// the controller on init and whenever the editor swaps to a new
    /// capture. `nil` = nothing selected.
    var selectedURL: URL? {
        didSet {
            // Session working set: an item opened from outside the recent
            // window stays pinned for the whole session (not just while
            // open) — the user returns to it via the strip like any other
            // tile. Dead/absorbed pins are cleaned in applyCurrent.
            // Dedupe by the standardized PATH: the open URL arrives without a
            // trailing slash while the indexed listing URL has one (a `.seal`
            // package is a directory URL) — and `standardizedFileURL` keeps that
            // slash, so a plain compare leaves the pin un-deduped and the capture
            // shows twice (e.g. after an undo-restore reopens it). `.path` drops
            // the slash so both sides match.
            if let url = selectedURL,
               // Scratch captures are open-but-not-in-the-Library, and the
               // strip is a Library surface: no pin until they are kept.
               !ScratchCapture.isScratch(url),
               !pinnedURLs.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                pinnedURLs.append(url)
            }
            // A programmatic open (launch / cross-item undo) reveals the item at
            // the strip's leading edge. Launch fires several async refreshes that
            // rebuild tiles and reset the scroll, so keep re-asserting the reveal
            // for a short window until the layout settles — a plain one-shot
            // scroll lands off-target.
            if !selectionFromStripClick { revealDeadline = Date().addingTimeInterval(1.2) }
            // Full re-apply (diff-based, cheap when nothing changed) so pin
            // tiles appear before selection/reveal runs.
            applyCurrent()
        }
    }

    /// Session-scoped working set of opened items that live outside the
    /// recent listing (newest pin first in the strip). Pruned when a pin's
    /// file vanishes or the item enters the listing naturally.
    private var pinnedURLs: [URL] = []

    /// True while a selection change originates from a click on THIS strip:
    /// the tile is already under the pointer, so the leading-align reveal
    /// (meant for Library opens / cross-item jumps landing from elsewhere)
    /// would yank the list sideways under the user's hand. Consumed by
    /// `applySelection`, which keeps only the minimal reveal for clicks.
    private var selectionFromStripClick = false

    init(
        mode: StripMode = .recent,
        folder: URL,
        daysBack: Int = 7,
        thumbHeight: CGFloat = 88,
        onSelect: @escaping (URL) -> Void
    ) {
        self.mode = mode
        self.folder = folder
        self.daysBack = daysBack
        self.thumbHeight = thumbHeight
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        applyBackgroundColor()
        buildScaffold()
        // Files dropped from Finder (etc.) onto the strip import into the
        // Library (recent mode only — see draggingEntered). Tiles are not
        // registered for drags, so drops land here even over a tile.
        registerForDraggedTypes([.fileURL])
        refresh()
    }

    /// Import handler for external file drops (wired by the controller to the
    /// same path as ⌘O / Import…). nil (or .deleted mode) refuses the drop.
    var onImportFiles: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard mode == .recent, onImportFiles != nil,
              !(sender.draggingSource is RecentThumbnailView),   // own tile drags
              sender.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        let importable = CaptureDragPayload.importableDropURLs(urls, saveFolder: folder)
        guard !importable.isEmpty else { return false }
        onImportFiles?(importable)
        return true
    }

    /// Fired on any mouse-down within the strip — a tile click (plain / ⌘ / ⇧)
    /// or a click on empty strip space. The controller uses it to mark the
    /// strip as the active surface so ⌘A selects all tiles (see
    /// EditorWindow.onSelectAll). Routing ⌘A through this flag — rather than
    /// real first responder — keeps the canvas as first responder for its own
    /// key handling, and survives the open that a plain tile click triggers.
    var onStripInteraction: (() -> Void)?

    /// ⌘A while the strip is the active surface: select every tile currently
    /// shown (the media-filtered, tab-scoped `orderedURLs`). No-op when empty.
    /// Anchor moves to the last tile so a follow-up ⇧-click ranges sensibly.
    func selectAll() {
        let urls = orderedURLs
        guard !urls.isEmpty else { return }
        selectedURLs = Set(urls)
        anchorURL = urls.last
        shiftFloor = selectedURLs
        refreshAffordances()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // Re-resolve the static cgColor background on a theme change (Settings
    // Light/Dark switch); the strip isn't rebuilt on a plain image switch.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColor()
    }

    /// Resolve the background cgColor against THIS view's effective appearance
    /// (not the ambient `NSAppearance.current`). Called from init,
    /// viewDidChangeEffectiveAppearance, and viewDidMoveToWindow (below).
    private func applyBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private func buildScaffold() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = thumbSpacing
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The stack lives inside a marquee container that always fills the
        // viewport width — so the empty area past the last tile is hittable
        // for a rubber-band drag (and the band can draw on top of tiles).
        let container = MarqueeView()
        container.stackView = stack
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        // Overlay scrollers (app-wide via AppleShowScrollBars=WhenScrolling)
        // auto-appear while scrolling and hide at rest, matching the rest of the
        // app. They float over the content and reserve no height.
        // Pin vertical motion entirely — the strip is single-row.
        scroll.verticalScrollElasticity = .none
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = container
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Stack left-packed; the container grows past it to the right.
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            // Pin container height to the *clip view* (not the outer scroll
            // view) so the legacy scroller's reserved height doesn't create
            // vertical overflow; width ≥ clip so it always fills the viewport.
            container.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        container.onMarqueeBegin = { [weak self] additive in self?.beginMarquee(additive: additive) }
        container.onMarqueeUpdate = { [weak self] rect in self?.updateMarquee(rect: rect) }
        container.onMarqueeEnd = { [weak self] in self?.endMarquee() }
        container.onEmptyClick = { [weak self] in
            self?.clearSelection()
            self?.dismissMarks(clicked: nil)
        }
        container.onPress = { [weak self] in self?.onStripInteraction?() }

        // Empty-state label, centered over the (then tile-less) scroll view.
        // Sits ABOVE the scroll view so it reads over the strip background, but
        // is non-interactive — the marquee container underneath still takes
        // clicks and rubber-band drags on the empty area.
        let empty = NSTextField(labelWithString: "")
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
        self.emptyLabel = empty

        self.stack = stack
        self.marqueeContainer = container
        applySelection()

        // Horizontal scrolling slides tiles under a stationary cursor;
        // AppKit's enter/exit tracking lags behind, leaving stale hover
        // chrome (delete buttons, scale) on tiles that passed through.
        // Re-derive hover from the actual mouse position on every scroll.
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncHoverToMouse() }
        }

        highlightObserver = NotificationCenter.default.addObserver(
            forName: ActivityHighlightStore.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshActivityMarks() }
        }

        // AI filename generation: show/clear the per-tile "refining" spinner.
        nameRefineStartObserver = NotificationCenter.default.addObserver(
            forName: .captureNameGenerationStarted, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let url = note.object as? URL else { return }
                self?.markNameRefining(url)
            }
        }
        nameRefineFinishObserver = NotificationCenter.default.addObserver(
            forName: .captureNameGenerationFinished, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let url = note.object as? URL else { return }
                self?.clearNameRefining(url)
            }
        }

        // A background reconcile that fills a previously-empty index has no
        // other way to reach the strip: refresh() runs on discrete UI/file
        // events, none of which fire when the index finishes building. Without
        // this the strip keeps rendering the stale empty listing until an
        // unrelated event — or an app restart — happens to refresh it.
        indexChangeObserver = NotificationCenter.default.addObserver(
            forName: .libraryIndexDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard stripShouldRefresh(forIndexChangeIn: note.object as? URL,
                                         watching: self.folder) else { return }
                self.refresh()
            }
        }
    }

    private var boundsObserver: NSObjectProtocol?
    private var nameRefineStartObserver: NSObjectProtocol?
    private var nameRefineFinishObserver: NSObjectProtocol?
    private var indexChangeObserver: NSObjectProtocol?

    /// Standardized URLs whose final filename is still being generated; their
    /// tiles show a spinner. Survives tile rebuilds via `applyRefiningState`.
    private var refiningURLs: Set<URL> = []
    private var refiningShownAt: [URL: Date] = [:]
    private var refiningTimeouts: [URL: DispatchWorkItem] = [:]

    /// Observes the shared highlight store so this strip repaints its
    /// delete/restore outlines whenever the marks change.
    private var highlightObserver: NSObjectProtocol?

    /// Observes this strip's window becoming key so the File-menu export command
    /// reflects the strip's selection when the editor window is brought forward.
    private var exportKeyObserver: NSObjectProtocol?

    /// Monotonic guard: only the most recently requested refresh may apply.
    private var refreshGeneration = 0

    /// Re-query the index (reconcile is mtime-keyed and cheap when nothing
    /// changed) and apply the result as a minimal diff. Safe to call often:
    /// tab switches, delete/restore, FSEvents.
    /// Where this strip's screen recordings live and get merged in: the
    /// Recordings folder for the Recent strip; the Deleted folder itself for the
    /// Deleted strip (trashed recordings sit there as video files alongside
    /// trashed captures).
    private var recordingsFolder: URL {
        switch mode {
        case .recent:  return RecordingsLibrary.folder(forSaveFolder: folder)
        case .deleted: return folder
        }
    }

    /// Show "No captures here yet." (or the filter-specific wording) whenever
    /// the strip has no tiles, so an empty strip reads as empty rather than as
    /// a blank bar that might still be loading.
    private func updateEmptyLabel() {
        let message = StripEmptyMessage.text(displayedCount: displayedItems.count,
                                             totalCount: allItems.count,
                                             filter: mediaFilter)
        emptyLabel?.stringValue = message ?? ""
        emptyLabel?.isHidden = message == nil
    }

    /// Re-point the strip at a different folder (the save location changed in
    /// Settings) and reload its tiles — the folder is otherwise fixed at init.
    func updateFolder(_ newFolder: URL) {
        guard newFolder != folder else { return }
        folder = newFolder
        refresh()
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let folder = folder
        let daysBack = daysBack
        let recordingsFolder = recordingsFolder
        Task { [weak self] in
            let indexed = await LibraryIndexStore.shared.stripItems(
                folder: folder, recordingsFolder: recordingsFolder,
                coveringDays: daysBack, now: Date())
            let items: [StripItem]
            if stripNeedsDirectScan(indexed: indexed) {
                items = await Self.fallbackItems(folder: folder, daysBack: daysBack)
            } else {
                // Reaching here means the listing is neither nil nor empty —
                // `stripNeedsDirectScan` covers both — so the coalesce is only
                // to satisfy the optional.
                items = indexed ?? []
            }
            guard let self, self.refreshGeneration == generation else { return }
            self.apply(items)
        }
    }

    /// Direct-scan fallback for a broken index DB: same cost as the old
    /// synchronous path, but off the main thread. Keeps the strip alive
    /// rather than empty when SQLite is unavailable.
    private static func fallbackItems(folder: URL, daysBack: Int) async -> [StripItem] {
        // The expensive disk scan runs off-main; display-name resolution stays
        // on the main actor (CaptureDisplayName.resolve is @MainActor — it may
        // consult the encryption session for locked packages).
        let urls = await Task.detached(priority: .userInitiated) {
            findRecentCaptures(in: folder, coveringDays: daysBack)
        }.value
        return urls.map { url in
            StripItem(url: url,
                      captureDate: .distantPast,
                      displayName: CaptureDisplayName.resolve(for: url))
        }
    }

    /// Apply a fresh listing with minimal churn: drop vanished tiles, build
    /// new ones (placeholder first, thumbnail async), and re-arrange only
    /// when order actually changed. Selection survives for URLs still shown.
    /// Show All files / Images / Videos. Re-filters the already-loaded listing
    /// without a reload when changed.
    var mediaFilter: StripMediaFilter = StripMediaFilterPreference.load() {
        didSet { if oldValue != mediaFilter { applyCurrent() } }
    }
    /// The full listing from the last refresh, before the media filter.
    private var allItems: [StripItem] = []
    /// The media-filtered listing in canonical display order (newest-first),
    /// recomputed on every `applyCurrent`. Backs `orderedURLs`.
    private var displayedItems: [StripItem] = []

    private func apply(_ items: [StripItem]) {
        allItems = items
        applyCurrent()
    }

    /// Whether a reused tile must be torn down and rebuilt because its video
    /// classification or indexed duration no longer matches the latest item.
    /// Both are fixed at construction and drive the thumbnail + play/duration
    /// badge, so an out-of-date tile (e.g. a `.seal` first listed before
    /// reconcile classified it as a video, or before its duration was indexed)
    /// would otherwise keep a stale image tile forever.
    static func tileNeedsRebuild(tileIsVideo: Bool, tileDuration: Double?, item: StripItem) -> Bool {
        tileIsVideo != item.isVideo || tileDuration != item.durationSeconds
    }

    private func applyCurrent() {
        guard let stack else { return }
        var items = allItems.filter { mediaFilter.includes(isVideo: $0.isVideo) }
        // Session working set: every item opened from outside the recent
        // window keeps a tile at the strip's front for the whole session —
        // the strip is the editor's "where am I" anchor, and cross-item undo
        // jumps and return visits need a landing spot. Front placement reads
        // as the working slots; the rest of the listing keeps its
        // chronology. Pins self-prune when their file vanishes or the item
        // enters the listing naturally; deleted-folder items belong to the
        // deleted strip and are never pinned here.
        if mode == .recent {
            pinnedURLs.removeAll { url in
                items.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })
                    || url.deletingLastPathComponent().lastPathComponent == "Deleted"
                    || ScratchCapture.isScratch(url)
                    || !FileManager.default.fileExists(atPath: url.path)
            }
            for url in pinnedURLs.reversed() {   // newest pin ends up first
                let item = Self.pinnedItem(for: url)
                // Pins obey the media filter like every other tile — an open
                // IMAGE must not surface under the Videos filter. The pin
                // itself survives (hidden, not dropped), so flipping the
                // filter back reveals it again.
                guard mediaFilter.includes(isVideo: item.isVideo) else { continue }
                items.insert(item, at: 0)
            }
        }
        // Canonical display order (newest-first, media-filtered) — the source of
        // truth for `orderedURLs`. Kept separate from `stack.arrangedSubviews`,
        // whose order can transiently scramble before a refresh settles.
        displayedItems = items
        updateEmptyLabel()
        videoItems = Dictionary(items.filter(\.isVideo).map { ($0.url, $0.isEncrypted) },
                                uniquingKeysWith: { first, _ in first })
        let existing = stack.arrangedSubviews.compactMap { $0 as? RecentThumbnailView }
        var tilesByURL = Dictionary(existing.map { ($0.fileURL, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let diff = stripDiff(old: existing.map(\.fileURL), new: items.map(\.url))

        // Drop tiles for vanished URLs, plus any reused tile whose video/duration
        // metadata went stale — a `.seal` first listed before reconcile (encrypted
        // session locked at launch) classified it as a video, or before its
        // duration was indexed, keeps a stale image tile that never gains the
        // play/duration badge unless rebuilt.
        let stale = items.filter { item in
            guard let tile = tilesByURL[item.url] else { return false }
            return Self.tileNeedsRebuild(tileIsVideo: tile.isVideo,
                                         tileDuration: tile.providedDurationSeconds,
                                         item: item)
        }.map(\.url)
        for url in diff.removed + stale {
            guard let tile = tilesByURL.removeValue(forKey: url) else { continue }
            tile.loadTask?.cancel()
            stack.removeArrangedSubview(tile)
            tile.removeFromSuperview()
        }

        if !diff.inserted.isEmpty || diff.orderChanged || !stale.isEmpty {
            for (index, item) in items.enumerated() {
                let tile = tilesByURL[item.url] ?? makeThumbnailView(for: item)
                tilesByURL[item.url] = tile
                tile.setDisplayName(item.displayName)
                stack.insertArrangedSubview(tile, at: index)
            }
        } else {
            // Names can change without membership/order changing (rename).
            for item in items { tilesByURL[item.url]?.setDisplayName(item.displayName) }
        }

        let surviving = Set(items.map(\.url))
        selectedURLs.formIntersection(surviving)
        shiftFloor.formIntersection(surviving)
        if let anchor = anchorURL, !surviving.contains(anchor) { anchorURL = nil }
        refreshAffordances()
        applySelection()
        applyRefiningState()
        onContentApplied?()
        // Tiles for recently delete/restored URLs may have just (re)appeared
        // (e.g. on a tab switch) — re-apply the outline.
        refreshActivityMarks()
    }

    /// A minimal StripItem for an open capture outside the indexed window.
    /// Video classification mirrors the editor's (manifest probe for .seal);
    /// duration stays nil (no badge) until the index lists the item properly.
    private static func pinnedItem(for url: URL) -> StripItem {
        let ext = url.pathExtension.lowercased()
        let isVideo = ["mov", "mp4", "sealrec"].contains(ext)
            || (ext == "seal" && (try? SealMetadataStore.readManifest(at: url))?.video != nil)
        let created = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate]) as? Date
        return StripItem(url: url,
                         captureDate: created ?? .distantPast,
                         displayName: CaptureDisplayName.resolve(for: url),
                         isVideo: isVideo,
                         isEncrypted: ext == "sealrec")
    }

    /// Reveal the tile as the FIRST item in the viewport (leading-aligned) —
    /// a Library open should land the eye on the open item immediately, not
    /// merely have it minimally visible at the trailing edge.
    private func scrollToLeading(_ thumb: RecentThumbnailView) {
        guard let scroll = thumb.enclosingScrollView, let doc = scroll.documentView else {
            thumb.scrollToVisible(thumb.bounds)
            return
        }
        scroll.layoutSubtreeIfNeeded()   // fresh tiles need real frames first
        let frame = thumb.convert(thumb.bounds, to: doc)
        let maxX = max(0, doc.frame.width - scroll.contentView.bounds.width)
        let x = min(max(0, frame.minX - 8), maxX)
        scroll.contentView.scroll(to: NSPoint(x: x, y: scroll.contentView.bounds.origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let highlightObserver { NotificationCenter.default.removeObserver(highlightObserver) }
        if let exportKeyObserver { NotificationCenter.default.removeObserver(exportKeyObserver) }
        if let nameRefineStartObserver { NotificationCenter.default.removeObserver(nameRefineStartObserver) }
        if let nameRefineFinishObserver { NotificationCenter.default.removeObserver(nameRefineFinishObserver) }
        if let indexChangeObserver { NotificationCenter.default.removeObserver(indexChangeObserver) }
        refiningTimeouts.values.forEach { $0.cancel() }
    }

    /// Track window changes so the export menu's selection reflects this strip
    /// only while its window is frontmost. Clears when the strip leaves a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Repaint against the window's real appearance: a bare `…cgColor` at init
        // resolves against the ambient appearance, which can differ from the
        // window's (app theme override) with no appearance CHANGE to correct it.
        applyBackgroundColor()
        if let exportKeyObserver { NotificationCenter.default.removeObserver(exportKeyObserver) }
        exportKeyObserver = nil
        guard let window else {
            ExportMenuState.shared.clear(owner: .editorStrip)
            return
        }
        exportKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishExportSelection() }
        }
        publishExportSelection()
    }

    /// Publish the current strip selection to the File-menu export command,
    /// but only while this strip's window is key (so a background reload can't
    /// clobber the Library's selection).
    private func publishExportSelection() {
        guard window?.isKeyWindow == true else { return }
        // Snapshot by value; display-name resolution (manifest reads) happens
        // only if an export command actually fires.
        let urls = selectedURLs
        let videos = videoItems
        ExportMenuState.shared.update(
            isEmpty: urls.isEmpty,
            hasVideo: urls.contains { videos[$0] != nil },
            owner: .editorStrip,
            provider: {
                urls.map { url in
                    SharePackageSource(url: url,
                                       displayName: CaptureDisplayName.resolve(for: url),
                                       isVideo: videos[url] != nil)
                }
            })
    }

    /// Present the encrypted-package export sheet for the given strip URLs
    /// (called from the right-click menu, single or bulk).
    func presentExport(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let sources = urls.map { url in
            SharePackageSource(url: url,
                               displayName: CaptureDisplayName.resolve(for: url),
                               isVideo: videoItems[url] != nil)
        }
        ExportPackageCoordinator.present(sources: sources, host: window)
    }

    /// Present "Export to Image" for the given strip URLs (right-click, single or bulk).
    func presentImageExport(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let sources = urls.map { url in
            SharePackageSource(url: url,
                               displayName: CaptureDisplayName.resolve(for: url),
                               isVideo: videoItems[url] != nil)
        }
        ExportImageCoordinator.present(sources: sources, host: window)
    }

    /// Present "Export to Video…" for the given strip URLs (right-click, single or bulk).
    func presentVideoExport(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let sources = urls.map { url in
            SharePackageSource(url: url,
                               displayName: CaptureDisplayName.resolve(for: url),
                               isVideo: videoItems[url] != nil)
        }
        VideoExportCoordinator.present(sources: sources, host: window)
    }

    /// Returns true if any of the given URLs maps to a video item in the strip.
    func hasVideo(in urls: some Collection<URL>) -> Bool {
        urls.contains(where: { videoItems[$0] != nil })
    }

    /// How many of the given URLs are video items in the strip.
    func videoCount(in urls: some Collection<URL>) -> Int {
        urls.filter { videoItems[$0] != nil }.count
    }

    /// Reflect the shared highlight store onto each tile's outline. Called when
    /// the store changes and at the end of `apply` (so tiles that appear after
    /// an async refresh — e.g. on a tab switch — pick up the outline). Reading
    /// the store means a freshly-created strip shows the current marks too.
    private func refreshActivityMarks() {
        guard let stack else { return }
        let store = ActivityHighlightStore.shared
        for case let tile as RecentThumbnailView in stack.arrangedSubviews {
            tile.isActivityMarked = store.contains(tile.fileURL)
        }
    }

    /// A click in the strip dismisses the marks unless it landed on a marked
    /// tile — handled centrally by the store, which clears them everywhere and
    /// notifies every strip / the Library to repaint.
    private func dismissMarks(clicked: URL?) {
        ActivityHighlightStore.shared.dismiss(clicked: clicked)
    }

    /// Make every tile's hover chrome match where the cursor ACTUALLY is.
    private func syncHoverToMouse() {
        guard let stack, let window else { return }
        let mouse = window.mouseLocationOutsideOfEventStream
        for case let tile as RecentThumbnailView in stack.arrangedSubviews {
            let local = tile.convert(mouse, from: nil)
            tile.setHovered(tile.bounds.contains(local))
        }
    }

    /// The selection we last scrolled into view, so a plain content refresh
    /// (e.g. after a delete) doesn't yank the scroll back to the open capture —
    /// we only auto-scroll when the selection actually changes.
    private var lastScrolledSelection: URL?
    /// While set to a future time, a programmatic selection keeps re-scrolling to
    /// the leading edge on each refresh (launch fires several that reset the
    /// scroll). Cleared once elapsed so it never fights the user afterwards.
    private var revealDeadline: Date?

    private func applySelection() {
        guard let stack else { return }
        var selectedThumb: RecentThumbnailView?
        // Path-based compare: the open URL can lack the trailing slash the
        // indexed tile URL carries (a `.seal` package is a directory), so a raw
        // `==` would fail to find the tile → no open ring and no scroll-to-it.
        let selectedKey = selectedURL?.standardizedFileURL.path
        for view in stack.arrangedSubviews {
            guard let thumb = view as? RecentThumbnailView else { continue }
            let match = (thumb.fileURL.standardizedFileURL.path == selectedKey)
            thumb.isOpen = match
            if match { selectedThumb = thumb }
        }
        if let selectedThumb {
            // A programmatic reveal keeps re-scrolling to the leading edge on
            // every refresh until its window elapses (launch rebuilds tiles a few
            // times, each resetting the scroll). A plain content refresh otherwise
            // only scrolls when the selection actually changed (so it doesn't yank
            // the scroll back), and a user click just nudges the tile fully visible.
            let revealing = !selectionFromStripClick && (revealDeadline.map { Date() < $0 } ?? false)
            if selectedURL != lastScrolledSelection || revealing {
                if selectionFromStripClick {
                    selectedThumb.scrollToVisible(selectedThumb.bounds)
                } else {
                    scrollToLeading(selectedThumb)
                }
            }
            lastScrolledSelection = selectedURL
            selectionFromStripClick = false
        }
    }

    /// Remove all selection state and repaint thumbnails. Called from the
    /// controller via the window's onClearSelection closure (Esc key) and
    /// explicitly from mountStrip on every tab switch.
    func clearSelection() {
        guard !selectedURLs.isEmpty else { return }
        selectedURLs.removeAll()
        anchorURL = nil
        shiftFloor = []
        refreshAffordances()
    }

    /// Put the multi-selection back on the actually-open file. Called when a
    /// click's open FAILED (e.g. a capture written by a newer build): the tile
    /// was optimistically multi-selected in `handlePlainClick` before the open
    /// was attempted, so without this the failed tile keeps its ring while the
    /// still-open file keeps its own — two highlighted tiles.
    func restoreSelectionToOpenFile() {
        selectedURLs = selectedURL.map { [$0] } ?? []
        anchorURL = selectedURL
        shiftFloor = selectedURLs
        refreshAffordances()
    }

    /// Reflect a programmatic open (e.g. the post-delete fallback) in the strip
    /// EXACTLY as a manual click would: a single click-selection with the same
    /// highlight — so it looks identical to clicking the tile, and a later click
    /// (which sets `selectedURLs = [other]`) replaces it instead of leaving two
    /// highlighted tiles. Does NOT open the file (the caller already did).
    func selectAsClicked(_ url: URL) {
        // A scratch capture has no tile here — it isn't in the Library, and
        // the strip is a Library surface. "Selecting" it would leave whatever
        // tile WAS highlighted still painted, pointing at an image that is not
        // the one on the canvas. Open-but-unlisted shows as no selection.
        guard !ScratchCapture.isScratch(url) else {
            clearSelection()
            return
        }
        selectedURLs = [url]
        anchorURL = url
        shiftFloor = [url]
        refreshAffordances()
    }

    /// Begin showing the "refining" spinner on `url`'s tile while its AI filename
    /// is generated. Backed by an 8s timeout so it can never hang.
    func markNameRefining(_ url: URL) {
        let key = url.standardizedFileURL
        guard !refiningURLs.contains(key) else { return }
        refiningURLs.insert(key)
        refiningShownAt[key] = Date()
        applyRefiningState()
        let timeout = DispatchWorkItem { [weak self] in self?.clearNameRefining(url, force: true) }
        refiningTimeouts[key] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    /// Stop the spinner for `url`. Honors a ~400ms minimum visible duration so a
    /// fast resolution doesn't strobe (unless `force`, e.g. the timeout fired).
    func clearNameRefining(_ url: URL, force: Bool = false) {
        let key = url.standardizedFileURL
        guard refiningURLs.contains(key) else { return }
        if !force, let shown = refiningShownAt[key] {
            let elapsed = Date().timeIntervalSince(shown)
            if elapsed < 0.4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.4 - elapsed)) { [weak self] in
                    self?.clearNameRefining(url, force: true)
                }
                return
            }
        }
        refiningTimeouts[key]?.cancel()
        refiningTimeouts[key] = nil
        refiningShownAt[key] = nil
        refiningURLs.remove(key)
        applyRefiningState()
    }

    /// Reflect `refiningURLs` onto each tile's spinner. Re-run on every content
    /// apply so a tile that (re)appears mid-generation picks up its spinner.
    private func applyRefiningState() {
        guard let stack else { return }
        for view in stack.arrangedSubviews {
            guard let thumb = view as? RecentThumbnailView else { continue }
            thumb.isNameRefining = refiningURLs.contains(thumb.fileURL.standardizedFileURL)
        }
    }

    /// Walk the thumbnail subviews and reflect the current selection state
    /// onto each one's `isMultiSelected` flag. The × / ↺ corner button
    /// stays available on selected thumbnails — there it applies to the
    /// whole selection (same as the right-click bulk menu).
    private func refreshAffordances() {
        guard let stack else { return }
        for view in stack.arrangedSubviews {
            guard let thumb = view as? RecentThumbnailView else { continue }
            thumb.isMultiSelected = selectedURLs.contains(thumb.fileURL)
        }
    }

    /// Plain-click on a thumbnail. Replace the selection with just this
    /// URL, open it in the editor, and set it as the range anchor.
    /// If the URL is already the open file AND the only selection,
    /// this is a no-op (idempotent).
    func handlePlainClick(url: URL, autoPlayVideo: Bool = false) {
        selectionFromStripClick = true
        onStripInteraction?()
        dismissMarks(clicked: url)
        // Video: recordings can't be edited, so a click OPENS the video in the
        // canvas (switching to it, like selecting an image opens it). It opens
        // paused on the first frame; `autoPlayVideo` — the play-badge click —
        // starts playback immediately. Keyboard nav / neighbor switches open paused.
        if videoItems[url] != nil {
            selectedURLs = [url]
            anchorURL = url
            shiftFloor = [url]
            refreshAffordances()
            onPlayVideo?(url, autoPlayVideo)
            return
        }
        let alreadyJustThis = (selectedURLs == [url] && url == selectedURL)
        selectedURLs = [url]
        anchorURL = url
        shiftFloor = [url]
        if !alreadyJustThis {
            onSelect(url)
        }
        refreshAffordances()
    }

    /// Sources for a drag beginning on `url`: the whole multi-selection when
    /// that tile is part of it (display order), else just the tile.
    func dragSources(anchoredAt url: URL) -> [CaptureDragPayload.Source] {
        let urls: [URL] = selectedURLs.contains(url)
            ? orderedURLs.filter { selectedURLs.contains($0) }
            : [url]
        return urls.compactMap { u in
            guard let item = displayedItems.first(where: { $0.url == u }) else { return nil }
            return CaptureDragPayload.Source(url: u, displayName: item.displayName,
                                             isVideo: item.isVideo)
        }
    }

    /// A companion tile's thumbnail for the drag image (nil if not on screen).
    func tileImage(for url: URL) -> NSImage? {
        guard let stack else { return nil }
        for case let tile as RecentThumbnailView in stack.arrangedSubviews
        where tile.fileURL == url {
            return tile.image
        }
        return nil
    }

    /// The URLs currently shown in the strip, in canonical display order
    /// (newest-first, after the media filter) — used for adjacent navigation,
    /// range-selection, and post-delete neighbor selection.
    ///
    /// Sourced from the sorted model (`displayedItems`), NOT the live
    /// `arrangedSubviews`: the view hierarchy's order can transiently scramble
    /// (recently opened/played tiles cluster at the front until a refresh
    /// settles), which would mis-pick the post-delete neighbor — the
    /// "random pick" bug. See `StripItem.merged` for the canonical order.
    var orderedURLs: [URL] { displayedItems.map(\.url) }

    /// Move the open file by `offset` tiles (−1 = previous/left, +1 =
    /// next/right) and open the neighbor. Anchors on the currently-open file
    /// (`selectedURL`); with none open, starts at the near end. Clamps at the
    /// ends (no wrap). Returns true if the strip had any tiles to navigate.
    @discardableResult
    func selectAdjacent(offset: Int) -> Bool {
        let urls = orderedURLs
        guard !urls.isEmpty else { return false }

        // Anchor on the last clicked/navigated tile (`anchorURL`) — which tracks
        // a playing video too — not just `selectedURL`, which only follows the
        // open image and goes stale while a video plays.
        let current = (anchorURL ?? selectedURL).flatMap { urls.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = max(0, min(urls.count - 1, current + offset))
        } else {
            next = offset >= 0 ? 0 : urls.count - 1
        }
        // Already at the end in the pressed direction: consume the key (so it
        // doesn't fall through) but don't re-open the same file.
        if next == current { return true }
        handlePlainClick(url: urls[next])
        return true
    }

    /// Jump to the first (`toEnd == false`) or last tile and open it — the
    /// ⌘←/⌘→ analogue of `selectAdjacent`. Consumes the key even when already at
    /// that end. Returns true if the strip had any tiles.
    @discardableResult
    func selectExtreme(toEnd: Bool) -> Bool {
        let urls = orderedURLs
        guard !urls.isEmpty else { return false }
        let target = toEnd ? urls.count - 1 : 0
        let current = (anchorURL ?? selectedURL).flatMap { urls.firstIndex(of: $0) }
        if current == target { return true }
        handlePlainClick(url: urls[target])
        return true
    }

    /// ⌘-click toggles a URL in/out of the selection without opening it.
    /// If adding, also updates the anchor (so a follow-up ⇧-click ranges
    /// from this point).
    func handleCmdClick(url: URL) {
        onStripInteraction?()
        dismissMarks(clicked: url)
        if selectedURLs.contains(url) {
            selectedURLs.remove(url)
            if anchorURL == url { anchorURL = nil }
        } else {
            selectedURLs.insert(url)
            anchorURL = url
        }
        // A ⇧-click after cherry-picking with ⌘ extends from this set.
        shiftFloor = selectedURLs
        refreshAffordances()
    }

    /// ⇧-click extends the selection to the inclusive range from the anchor to
    /// this URL, unioned with the floor so a prior marquee or ⌘-click set is
    /// preserved rather than replaced. Does NOT change the open file. If no
    /// anchor exists, degrades to a plain ⌘-click (toggle one).
    func handleShiftClick(url: URL) {
        onStripInteraction?()
        dismissMarks(clicked: url)
        let anchor = anchorURL ?? selectedURL
        guard let anchorURL = anchor else {
            // No anchor; degrade to single-add (no range).
            handleCmdClick(url: url)
            return
        }
        let urls = orderedURLs
        guard let anchorIdx = urls.firstIndex(of: anchorURL),
              let targetIdx = urls.firstIndex(of: url) else {
            return
        }
        let range = anchorIdx <= targetIdx ? anchorIdx...targetIdx : targetIdx...anchorIdx
        selectedURLs = Set(urls[range]).union(shiftFloor)
        // Anchor and floor stay — successive ⇧-clicks rebase from the same
        // origin and keep preserving the block that was already selected.
        refreshAffordances()
    }

    // MARK: - Marquee (rubber-band) selection

    /// Selection captured when a marquee starts: the prior selection for an
    /// additive (⌘/⇧) drag, empty for a plain drag (which replaces).
    private var marqueeBase: Set<URL> = []

    private func beginMarquee(additive: Bool) {
        dismissMarks(clicked: nil)   // a marquee is a selection elsewhere
        marqueeBase = additive ? selectedURLs : []
    }

    /// Live-update the multi-selection from the band rect (in the stack's
    /// coordinate space). Touch = select; does NOT change the open file.
    private func updateMarquee(rect: CGRect) {
        guard let stack, let container = marqueeContainer else { return }
        // Tile frames live in the stack's space; the band rect is in the
        // container's. Convert each tile into container space to hit-test.
        var frames: [URL: CGRect] = [:]
        for view in stack.arrangedSubviews {
            guard let thumb = view as? RecentThumbnailView else { continue }
            frames[thumb.fileURL] = container.convert(thumb.bounds, from: thumb)
        }
        let touched = MarqueeSelection.touched(rect: rect, frames: frames)
        selectedURLs = MarqueeSelection.combine(touched: touched, base: marqueeBase)
        // The anchor/floor are finalized in `endMarquee`; during the drag the
        // selection is still in flux, so leave the anchor cleared.
        anchorURL = nil
        refreshAffordances()
    }

    /// Marquee drag ended with `selectedURLs` set live. Record it as the floor
    /// and anchor a follow-up ⇧-click on the last selected tile (in display
    /// order), so shift-clicking after a marquee extends the block instead of
    /// collapsing to the clicked tile.
    private func endMarquee() {
        marqueeBase = []
        shiftFloor = selectedURLs
        anchorURL = orderedURLs.last(where: { selectedURLs.contains($0) })
    }

    private func makeThumbnailView(for item: StripItem) -> RecentThumbnailView {
        // Placeholder first; the decoded thumbnail lands asynchronously via
        // the shared ThumbnailStore (same cache the Library uses).
        let thumbWidth = (thumbHeight * thumbAspect).rounded()
        let tileHeight = thumbHeight + labelHeight

        let view = RecentThumbnailView(
            fileURL: item.url,
            image: NSImage(),
            displayName: item.displayName,
            mode: mode,
            isVideo: item.isVideo,
            isEncrypted: item.isEncrypted,
            durationSeconds: item.durationSeconds,
            thumbHeight: thumbHeight,
            thumbAspect: thumbAspect,
            frame: NSRect(x: 0, y: 0, width: thumbWidth, height: tileHeight)
        )
        view.onSelect = onSelect
        view.onDelete = { [weak self] url in self?.onDelete?(url) }
        view.onRestore = { [weak self] url in self?.onRestore?(url) }
        view.loadTask = Task { [weak view] in
            guard let image = await Self.loadThumbnail(for: item.url, isVideo: item.isVideo),
                  !Task.isCancelled else { return }
            view?.setImage(image)
        }
        return view
    }

    /// Decode a tile's thumbnail: video frames (handling encrypted `.sealrec`)
    /// via `VideoThumbnail`, image captures via the shared `ThumbnailStore`.
    /// Nil → the placeholder stays (e.g. an encrypted recording while locked).
    @MainActor
    private static func loadThumbnail(for url: URL, isVideo: Bool) async -> NSImage? {
        if isVideo {
            guard let cg = await VideoThumbnail.load(for: url) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return await ThumbnailStore.shared.thumbnail(for: url)
    }

    /// Live-resize the thumbnails (called continuously while the user drags
    /// the strip's resize handle). Each tile redraws its already-loaded image
    /// at the new size, so there is no disk reload. Idempotent for an unchanged
    /// height.
    func setThumbHeight(_ height: CGFloat) {
        guard height != thumbHeight else { return }
        thumbHeight = height
        guard let stack else { return }
        for case let tile as RecentThumbnailView in stack.arrangedSubviews {
            tile.setThumbHeight(height)
        }
    }

    /// Re-run every tile's thumbnail load. Used after the encryption session
    /// unlocks: tiles built while locked decoded to nil (placeholder) and never
    /// retry on their own, so without this the strip stays blank until a click
    /// rebuilds it.
    func reloadThumbnails() {
        guard let stack else { return }
        for case let tile as RecentThumbnailView in stack.arrangedSubviews {
            let url = tile.fileURL
            let isVideo = tile.isVideo
            tile.loadTask?.cancel()
            tile.loadTask = Task { [weak tile] in
                guard let image = await Self.loadThumbnail(for: url, isVideo: isVideo),
                      !Task.isCancelled else { return }
                tile?.setImage(image)
            }
        }
    }

    /// Replace the displayed image for the tile matching `url`, if one is
    /// currently shown. Lets the editor keep the open file's thumbnail in
    /// sync with unsaved annotation edits.
    @discardableResult
    func updateThumbnail(for url: URL, image: NSImage) -> Int {
        guard let stack = stack else { return 0 }
        var matched = 0
        for case let tile as RecentThumbnailView in stack.arrangedSubviews where tile.fileURL == url {
            tile.loadTask?.cancel()
            tile.setImage(image)
            matched += 1
        }
        return matched
    }

}

/// Thumbnail tile that supports both click-to-open (calls `onSelect`) and
/// drag-out (writes the file URL to the drag pasteboard so the user can
/// drop the PNG into any app that accepts files — Finder, Slack, Mail…).
final class RecentThumbnailView: NSView, NSDraggingSource {

    let fileURL: URL
    private(set) var image: NSImage
    private var displayName: String
    let mode: StripMode
    /// Screen-recording tile: draws a play badge, and a locked/film placeholder
    /// when no thumbnail decoded (encrypted `.sealrec` while the session is locked).
    let isVideo: Bool
    let isEncrypted: Bool
    var onSelect: ((URL) -> Void)?
    var onDelete: ((URL) -> Void)?
    var onRestore: ((URL) -> Void)?
    var loadTask: Task<Void, Never>?

    private var mouseDownPoint: NSPoint?
    private let dragThreshold: CGFloat = 4
    private let cornerButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var displayNameLabel: NSTextField?
    private var refiningSpinner: NSProgressIndicator?

    /// While true, a small spinner next to the (provisional) name shows the
    /// final filename is still being generated (AI title pending).
    var isNameRefining: Bool = false {
        didSet {
            guard isNameRefining != oldValue else { return }
            if isNameRefining { refiningSpinner?.startAnimation(nil) }
            else { refiningSpinner?.stopAnimation(nil) }
        }
    }

    /// Swap the displayed image (used to mirror live editor edits onto the
    /// open file's tile). Triggers a repaint.
    func setImage(_ newImage: NSImage) {
        image = newImage
        needsDisplay = true
    }

    /// Persistent "just delete/restored" outline. Set by the strip after a
    /// delete/restore (or its undo/redo); cleared when the user clicks
    /// elsewhere. Drawn as a distinct orange ring in `draw(_:)`.
    var isActivityMarked: Bool = false {
        didSet { if isActivityMarked != oldValue { needsDisplay = true } }
    }

    var isOpen: Bool = false {
        didSet { if isOpen != oldValue { applyBorder(); needsDisplay = true } }
    }

    var isMultiSelected: Bool = false {
        didSet {
            if isMultiSelected != oldValue {
                applyBorder()
                needsDisplay = true
            }
        }
    }

    /// Height of the image portion of the tile (the label lives below it).
    /// Mutable so the strip can live-resize tiles via `setThumbHeight`.
    private var thumbHeight: CGFloat
    /// Fixed width ÷ height ratio used to keep the tile a 4:3 box as it scales.
    private let thumbAspect: CGFloat
    /// Owned so `setThumbHeight` can re-drive width and the label baseline.
    private var widthConstraint: NSLayoutConstraint?
    private var labelTopConstraint: NSLayoutConstraint?
    private var cornerButtonWidthConstraint: NSLayoutConstraint?
    private var cornerButtonHeightConstraint: NSLayoutConstraint?

    /// The × / ↺ corner button hugs the upper-left corner (slight negative inset
    /// so it nudges into the very corner, overhanging the tile a touch) and
    /// scales with the tile so it stays proportional as the strip is resized.
    private static let cornerButtonInset: CGFloat = -3

    /// Corner-button edge length scaled to the tile height (×0.25), clamped to a
    /// usable range so it stays clickable on a short strip and doesn't dominate a
    /// tall one. 88pt (the default height) → 22pt, matching the prior fixed size.
    static func cornerButtonSize(forThumbHeight height: CGFloat) -> CGFloat {
        min(28, max(16, (height * 0.25).rounded()))
    }

    init(fileURL: URL, image: NSImage, displayName: String, mode: StripMode, isVideo: Bool = false, isEncrypted: Bool = false, durationSeconds: Double? = nil, thumbHeight: CGFloat, thumbAspect: CGFloat, frame: NSRect) {
        self.fileURL = fileURL
        self.image = image
        self.displayName = displayName
        self.mode = mode
        self.isVideo = isVideo
        self.isEncrypted = isEncrypted
        self.indexedDurationSeconds = durationSeconds
        self.thumbHeight = thumbHeight
        self.thumbAspect = thumbAspect
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = false   // shadow needs to escape
        layer?.shadowOpacity = 0.12
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 4
        layer?.shadowColor = NSColor.black.cgColor
        // Filename as tooltip so hovering reveals the raw file name.
        toolTip = fileURL.lastPathComponent
        // Border/ring is now drawn in draw(_:); applyBorder() becomes
        // a needsDisplay trigger via the didSet observers.
        setupCornerButton()
        setupDisplayNameLabel()
        setupContextMenu()
        let width = widthAnchor.constraint(equalToConstant: (thumbHeight * thumbAspect).rounded())
        width.isActive = true
        widthConstraint = width
        loadDurationIfVideo()
    }

    deinit { loadTask?.cancel() }

    /// Duration from the library index (nil if unknown), preferred over the
    /// async loader: an AVURLAsset can't read a `.seal` video package.
    private let indexedDurationSeconds: Double?

    /// The indexed duration this tile was built with — so the strip can detect
    /// when a reused tile's metadata went stale and rebuild it.
    var providedDurationSeconds: Double? { indexedDurationSeconds }

    /// "m:ss" badge for video tiles, resolved (and cached) asynchronously.
    private var durationText: String?

    /// Test hook: the duration badge text currently set on the tile.
    var debugDurationText: String? { durationText }

    private func loadDurationIfVideo() {
        guard isVideo else { return }
        // The index already knows the duration for `.seal` videos (and an
        // AVURLAsset can't read a `.seal` package anyway), so use it directly.
        if let secs = indexedDurationSeconds {
            durationText = VideoPlaybackMath.timeLabel(secs); return
        }
        if let secs = VideoDurationLoader.cachedSeconds(for: fileURL) {
            durationText = VideoPlaybackMath.timeLabel(secs); return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let secs = await VideoDurationLoader.seconds(for: self.fileURL) {
                self.durationText = VideoPlaybackMath.timeLabel(secs)
                self.needsDisplay = true
            }
        }
    }

    /// Live-resize this tile to a new thumbnail height: re-drive the width and
    /// label baseline and repaint the in-memory image at the new size.
    func setThumbHeight(_ height: CGFloat) {
        guard height != thumbHeight else { return }
        thumbHeight = height
        widthConstraint?.constant = (height * thumbAspect).rounded()
        labelTopConstraint?.constant = height + 2
        applyCornerButtonMetrics()
        needsDisplay = true
    }

    private func setupDisplayNameLabel() {
        let label = NSTextField(labelWithString: displayName)
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        displayNameLabel = label
        let labelTop = label.topAnchor.constraint(equalTo: topAnchor, constant: thumbHeight + 2)
        labelTopConstraint = labelTop
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            labelTop,
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        // Small indeterminate spinner at the caption's leading edge, shown only
        // while the final filename is being generated (hidden when stopped).
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        refiningSpinner = spinner
        NSLayoutConstraint.activate([
            spinner.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    /// Update the caption (a rename changes displayName without changing
    /// the URL). No-op when unchanged.
    func setDisplayName(_ name: String) {
        guard displayNameLabel?.stringValue != name else { return }
        displayNameLabel?.stringValue = name
    }

    private func applyBorder() {
        // No-op for the layer's border (which is now nil) — the ring is
        // drawn manually in draw(_:). This method stays as a hook so the
        // existing didSet observers (isOpen, isMultiSelected) can still
        // call it; it just requests a redraw.
        needsDisplay = true
    }

    /// Tooltip / accessibility label for the corner action, per mode.
    private var cornerActionLabel: String {
        mode == .recent ? "Delete" : "Restore"
    }

    /// White glyph in a translucent dark disc (the photo-overlay idiom), sized to
    /// the button so it stays crisp at any strip height. `imageScaling` is
    /// `.scaleNone`, so the glyph point size must match the button size here.
    private func cornerSymbolImage(pointSize: CGFloat) -> NSImage? {
        let symbolName = mode == .recent
            ? "xmark.circle.fill"
            : "arrow.uturn.backward.circle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(paletteColors: [
                .white, NSColor.black.withAlphaComponent(0.55),
            ]))
        return NSImage(systemSymbolName: symbolName,
                       accessibilityDescription: cornerActionLabel)?
            .withSymbolConfiguration(config)
    }

    /// Apply the corner button's size and glyph for the current `thumbHeight`.
    /// The disc fills the button (glyph point size ≈ 0.86 × size, matching the
    /// prior 19pt-in-22pt ratio).
    private func applyCornerButtonMetrics() {
        let size = Self.cornerButtonSize(forThumbHeight: thumbHeight)
        cornerButtonWidthConstraint?.constant = size
        cornerButtonHeightConstraint?.constant = size
        cornerButton.image = cornerSymbolImage(pointSize: (size * 0.86).rounded())
    }

    private func setupCornerButton() {
        cornerButton.isBordered = false
        cornerButton.bezelStyle = .regularSquare
        cornerButton.imageScaling = .scaleNone
        cornerButton.isHidden = true
        cornerButton.toolTip = cornerActionLabel
        cornerButton.target = self
        cornerButton.action = #selector(cornerButtonClicked)
        cornerButton.translatesAutoresizingMaskIntoConstraints = false
        cornerButton.wantsLayer = true
        cornerButton.layer?.shadowOpacity = 0.4
        cornerButton.layer?.shadowRadius = 2
        cornerButton.layer?.shadowOffset = CGSize(width: 0, height: -1)
        cornerButton.layer?.shadowColor = NSColor.black.cgColor
        addSubview(cornerButton)
        let width = cornerButton.widthAnchor.constraint(equalToConstant: 22)
        let height = cornerButton.heightAnchor.constraint(equalToConstant: 22)
        cornerButtonWidthConstraint = width
        cornerButtonHeightConstraint = height
        NSLayoutConstraint.activate([
            cornerButton.topAnchor.constraint(
                equalTo: topAnchor, constant: Self.cornerButtonInset),
            cornerButton.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.cornerButtonInset),
            width, height,
        ])
        applyCornerButtonMetrics()
    }

    private func setupContextMenu() {
        // Menu is built per right-click in `menu(for:)` below so it can
        // branch on whether this thumbnail is in the strip's selection.
        self.menu = nil   // ensure no static menu interferes
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let strip = enclosingStripView() else { return nil }
        let isBulk = strip.selectedURLs.contains(fileURL) && strip.selectedURLs.count > 1
        // Right-click selects + opens this item, so it shows the SAME single
        // highlight as a left click (the open ring) rather than a second
        // multi-select highlight. When the item is already part of a multi-
        // selection, leave the selection intact so bulk actions still apply.
        if !isBulk { strip.handlePlainClick(url: fileURL) }
        let menu = NSMenu()

        // Show in Finder — available on both tabs, single and bulk.
        let finderItem = NSMenuItem(
            title: "Show in Finder",
            action: isBulk ? #selector(bulkShowInFinderFromMenu) : #selector(showInFinderFromMenu),
            keyEquivalent: ""
        )
        finderItem.target = self
        menu.addItem(finderItem)

        // Show in Library — single item only; jumps to the Library tab and
        // highlights this capture there.
        if !isBulk {
            let libraryItem = NSMenuItem(
                title: "Show in Library",
                action: #selector(showInLibraryFromMenu),
                keyEquivalent: ""
            )
            libraryItem.target = self
            menu.addItem(libraryItem)
        }

        // Export to Image — recent strip only, single or bulk selection.
        if mode == .recent {
            let imageItem = NSMenuItem(
                title: isBulk
                    ? "Export \(strip.selectedURLs.count) Images"
                    : "Export to Image",
                action: isBulk ? #selector(bulkExportImageFromMenu) : #selector(exportImageFromMenu),
                keyEquivalent: "")
            imageItem.target = self
            menu.addItem(imageItem)
        }
        // Export to Video — recent strip only, shown only when the selection contains a video.
        if mode == .recent {
            let videoURLs = isBulk ? Array(strip.selectedURLs) : [fileURL]
            let vCount = strip.videoCount(in: videoURLs)
            if vCount > 0 {
                let videoItem = NSMenuItem(
                    title: vCount > 1 ? "Export \(vCount) Videos…" : "Export to Video…",
                    action: isBulk ? #selector(bulkExportVideoFromMenu) : #selector(exportVideoFromMenu),
                    keyEquivalent: "")
                videoItem.target = self
                menu.addItem(videoItem)
            }
        }
        // Export Encrypted Package — recent strip only, single or bulk selection.
        if mode == .recent {
            let exportItem = NSMenuItem(
                title: isBulk
                    ? "Export \(strip.selectedURLs.count) Items as Package…"
                    : "Export to Package…",
                action: isBulk ? #selector(bulkExportFromMenu) : #selector(exportFromMenu),
                keyEquivalent: ""
            )
            exportItem.target = self
            menu.addItem(exportItem)
        }
        // Duplicate — recent strip only; copies the whole capture (all edits).
        if mode == .recent {
            let dupItem = NSMenuItem(
                title: isBulk ? "Duplicate \(strip.selectedURLs.count) Items" : "Duplicate",
                action: isBulk ? #selector(bulkDuplicateFromMenu) : #selector(duplicateFromMenu),
                keyEquivalent: "")
            dupItem.target = self
            menu.addItem(dupItem)
        }
        menu.addItem(NSMenuItem.separator())

        if isBulk {
            // Bulk: right-click on a SELECTED thumbnail when 2+ are selected.
            let count = strip.selectedURLs.count
            switch mode {
            case .recent:
                let item = NSMenuItem(
                    title: "Delete \(count) Items",
                    action: #selector(bulkDeleteFromMenu),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
            case .deleted:
                let restoreItem = NSMenuItem(
                    title: "Restore \(count) Items",
                    action: #selector(bulkRestoreFromMenu),
                    keyEquivalent: ""
                )
                restoreItem.target = self
                menu.addItem(restoreItem)

                menu.addItem(NSMenuItem.separator())

                let deleteItem = NSMenuItem(
                    title: "Delete \(count) Items Forever",
                    action: #selector(bulkPermanentDeleteFromMenu),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                menu.addItem(deleteItem)
            }
        } else {
            // Single-item: non-selected OR exactly one selected.
            switch mode {
            case .recent:
                let item = NSMenuItem(
                    title: "Delete",
                    action: #selector(deleteFromMenu),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
            case .deleted:
                let restoreItem = NSMenuItem(
                    title: "Restore",
                    action: #selector(restoreFromMenu),
                    keyEquivalent: ""
                )
                restoreItem.target = self
                menu.addItem(restoreItem)

                menu.addItem(NSMenuItem.separator())

                let deleteItem = NSMenuItem(
                    title: "Delete Forever",
                    action: #selector(permanentDeleteFromMenu),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                menu.addItem(deleteItem)
            }
        }
        return menu
    }

    @objc private func bulkDeleteFromMenu() {
        guard let strip = enclosingStripView() else { return }
        strip.onBulkDelete?(Array(strip.selectedURLs))
    }

    @objc private func bulkRestoreFromMenu() {
        guard let strip = enclosingStripView() else { return }
        strip.onBulkRestore?(Array(strip.selectedURLs))
    }

    @objc private func permanentDeleteFromMenu() {
        enclosingStripView()?.onPermanentDelete?(fileURL)
    }

    @objc private func bulkPermanentDeleteFromMenu() {
        guard let strip = enclosingStripView() else { return }
        strip.onBulkPermanentDelete?(Array(strip.selectedURLs))
    }

    @objc private func exportFromMenu() {
        enclosingStripView()?.presentExport(for: [fileURL])
    }

    @objc private func bulkExportFromMenu() {
        guard let strip = enclosingStripView() else { return }
        strip.presentExport(for: Array(strip.selectedURLs))
    }

    @objc private func exportImageFromMenu() {
        enclosingStripView()?.presentImageExport(for: [fileURL])
    }

    @objc private func bulkExportImageFromMenu() {
        guard let strip = enclosingStripView() else { return }
        strip.presentImageExport(for: Array(strip.selectedURLs))
    }

    @objc private func exportVideoFromMenu() {
        enclosingStripView()?.presentVideoExport(for: [fileURL])
    }

    @objc private func bulkExportVideoFromMenu() {
        guard let strip = enclosingStripView() else { return }
        strip.presentVideoExport(for: Array(strip.selectedURLs))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    /// Single source of truth for hover chrome (corner button + lift).
    /// Driven by tracking-area events AND by the strip's scroll-time
    /// re-sync, so tiles sliding under a stationary cursor can't strand
    /// stale chrome.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        cornerButton.isHidden = !hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            self.layer?.transform = hovered
                ? CATransform3DMakeScale(1.02, 1.02, 1.0)
                : CATransform3DIdentity
        }
    }

    @objc private func cornerButtonClicked() {
        fireModeAction()
    }

    @objc private func deleteFromMenu() {
        onDelete?(fileURL)
    }

    @objc private func restoreFromMenu() {
        onRestore?(fileURL)
    }

    @objc private func duplicateFromMenu() {
        CaptureDuplicator.duplicate([fileURL]) { CaptureDisplayName.resolve(for: $0) }
        enclosingStripView()?.refresh()
    }

    @objc private func bulkDuplicateFromMenu() {
        guard let strip = enclosingStripView() else { return }
        CaptureDuplicator.duplicate(Array(strip.selectedURLs)) { CaptureDisplayName.resolve(for: $0) }
        strip.refresh()
    }

    @objc private func showInFinderFromMenu() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func showInLibraryFromMenu() {
        enclosingStripView()?.onShowInLibrary?(fileURL)
    }

    @objc private func bulkShowInFinderFromMenu() {
        guard let strip = enclosingStripView() else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(strip.selectedURLs))
    }

    private func fireModeAction() {
        // Part of a multi-selection: the button means "act on the whole
        // selection", mirroring the right-click bulk menu.
        if let strip = enclosingStripView(),
           strip.selectedURLs.contains(fileURL), strip.selectedURLs.count > 1 {
            let urls = Array(strip.selectedURLs)
            switch mode {
            case .recent: strip.onBulkDelete?(urls)
            case .deleted: strip.onBulkRestore?(urls)
            }
            return
        }
        switch mode {
        case .recent: onDelete?(fileURL)
        case .deleted: onRestore?(fileURL)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { false }

    /// The centered sub-rectangle of a source image (in image points) whose
    /// aspect matches `dst`, for an aspect-fill (cover + center-crop) draw.
    /// Returns the full image rect when sizes are degenerate, so a missing
    /// or zero-sized image still draws something rather than nothing.
    static func aspectFillSourceRect(imageSize: NSSize, into dst: NSSize) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, dst.width > 0, dst.height > 0 else {
            return NSRect(origin: .zero, size: imageSize)
        }
        let dstAspect = dst.width / dst.height
        let imgAspect = imageSize.width / imageSize.height
        if imgAspect > dstAspect {
            // Source is wider than the box: keep full height, crop the sides.
            let w = imageSize.height * dstAspect
            return NSRect(x: (imageSize.width - w) / 2, y: 0, width: w, height: imageSize.height)
        } else {
            // Source is taller than the box: keep full width, crop top/bottom.
            let h = imageSize.width / dstAspect
            return NSRect(x: 0, y: (imageSize.height - h) / 2, width: imageSize.width, height: h)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }

        // The tile is non-flipped: origin is at bottom-left. The image occupies
        // the top `thumbHeight` points; the label NSTextField sits below it.
        // In non-flipped coordinates, "top" means high y values.
        let imageRect = NSRect(
            x: bounds.minX,
            y: bounds.maxY - thumbHeight,
            width: bounds.width,
            height: thumbHeight
        )

        // 1. Draw image clipped to the rounded card shape so the image's
        //    rectangular bounds get the corner rounding visually.
        ctx.saveGraphicsState()
        let cardPath = NSBezierPath(roundedRect: imageRect, xRadius: 8, yRadius: 8)
        cardPath.addClip()
        // Aspect-fill: draw a centered crop of the source whose aspect
        // matches the image area, so the image covers the box without stretching.
        let src = Self.aspectFillSourceRect(imageSize: image.size, into: imageRect.size)
        image.draw(in: imageRect, from: src, operation: .sourceOver, fraction: 1.0)
        if isMultiSelected && !isOpen {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            cardPath.fill()
        }
        ctx.restoreGraphicsState()

        // 1b. Video tiles: a film/lock placeholder when no thumbnail decoded
        //     (e.g. an encrypted .sealrec while the session is locked), plus a
        //     play badge so recordings read as playable, not editable.
        if isVideo {
            if image.size.width == 0 {
                ctx.saveGraphicsState()
                cardPath.addClip()
                NSColor(white: 0.12, alpha: 1).setFill()
                cardPath.fill()
                ctx.restoreGraphicsState()
                drawCenteredSymbol(isEncrypted ? "lock.fill" : "film",
                                   in: imageRect, pointSize: thumbHeight * 0.26,
                                   color: NSColor.white.withAlphaComponent(0.5))
            }
            let badge = (thumbHeight * 0.34).rounded()
            let disc = NSRect(x: imageRect.midX - badge / 2, y: imageRect.midY - badge / 2,
                              width: badge, height: badge)
            NSColor.black.withAlphaComponent(0.42).setFill()
            NSBezierPath(ovalIn: disc).fill()
            drawCenteredSymbol("play.fill", in: imageRect, pointSize: badge * 0.46, color: .white)
            if let durationText { drawDurationBadge(durationText, in: imageRect) }
            if let format = plainMovieFormatLabel { drawFormatBadge(format, in: imageRect) }
        }

        // 2. Ring (drawn AFTER the clip is restored so it traces the
        //    rounded edge cleanly). Open: 2pt; multi-selected: 1.5pt.
        //    Neither: no edge stroke — the shadow does the lifting.
        if isOpen {
            let ringPath = NSBezierPath(roundedRect: imageRect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.setStroke()
            ringPath.lineWidth = 2
            ringPath.stroke()
        } else if isMultiSelected {
            let ringPath = NSBezierPath(roundedRect: imageRect.insetBy(dx: 0.75, dy: 0.75), xRadius: 7.25, yRadius: 7.25)
            NSColor.controlAccentColor.setStroke()
            ringPath.lineWidth = 1.5
            ringPath.stroke()
        }

        // 3. Activity outline (delete/restore) — a distinct orange ring, drawn
        //    on top so it reads even when the tile is also selected/open.
        if isActivityMarked {
            let markPath = NSBezierPath(roundedRect: imageRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 6.5, yRadius: 6.5)
            NSColor.systemOrange.setStroke()
            markPath.lineWidth = 3
            markPath.stroke()
        }
    }

    /// Draw a small "m:ss" duration pill in the bottom-right of `rect`.
    /// "MOV"/"MP4" for a recording saved WITHOUT the package wrapper; nil for a
    /// `.seal`. Absence carries the meaning — labelling every package "SEAL"
    /// would put jargon on the common case, and the tile's tooltip already
    /// shows the full filename for anyone who wants certainty.
    ///
    /// It answers the question that made this setting exist: can I use this
    /// file as it is, or does it need exporting first?
    private var plainMovieFormatLabel: String? {
        let ext = fileURL.pathExtension.lowercased()
        guard plainMovieExtensions.contains(ext) else { return nil }
        return ext.uppercased()
    }

    /// Format pill, top-RIGHT. Mirrors `drawDurationBadge`'s recipe (same font
    /// scaling, padding and margin) so the two read as one family; they sit in
    /// opposite corners and can never collide. Hidden on small tiles, where a
    /// third overlay on top of the play and duration badges is clutter rather
    /// than information.
    private func drawFormatBadge(_ text: String, in rect: NSRect) {
        guard thumbHeight >= Self.formatBadgeMinThumbHeight else { return }
        let font = NSFont.systemFont(ofSize: max(9, thumbHeight * 0.13), weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 5, padY: CGFloat = 2, margin: CGFloat = 5
        let pill = NSRect(x: rect.maxX - size.width - padX * 2 - margin,
                          y: rect.maxY - size.height - padY * 2 - margin,
                          width: size.width + padX * 2, height: size.height + padY * 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + padX, y: pill.minY + padY), withAttributes: attrs)
    }

    /// Below this thumbnail height the format pill is dropped: the tile already
    /// carries a play badge and a duration badge, and three overlays on a tiny
    /// square stop being readable.
    ///
    /// Sized against the REAL default (88pt of thumbnail, `RecentStripView`'s
    /// `thumbHeight` parameter — not the 146pt strip height, which includes the
    /// label row). An earlier 140 floor hid the badge at every normal size.
    static let formatBadgeMinThumbHeight: CGFloat = 64

    private func drawDurationBadge(_ text: String, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: max(9, thumbHeight * 0.13), weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 5, padY: CGFloat = 2, margin: CGFloat = 5
        let pill = NSRect(x: rect.maxX - size.width - padX * 2 - margin,
                          y: rect.minY + margin,
                          width: size.width + padX * 2, height: size.height + padY * 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + padX, y: pill.minY + padY), withAttributes: attrs)
    }

    /// Draw an SF Symbol, tinted via a palette configuration, centered in `rect`.
    private func drawCenteredSymbol(_ name: String, in rect: NSRect, pointSize: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let origin = NSPoint(x: (rect.midX - size.width / 2).rounded(),
                             y: (rect.midY - size.height / 2).rounded())
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // Receive the very first click in a window that isn't yet key — without
    // this, the user would need to click the strip twice (once to focus,
    // once to drag/select) when returning from another app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Release the PREVIOUS drag's promise-delegate lifelines (see
        // activeDragRetainers) now that a new gesture is starting.
        activeDragRetainers.removeAll()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x
        let dy = current.y - start.y
        if dx * dx + dy * dy < dragThreshold * dragThreshold { return }

        mouseDownPoint = nil

        // Drag out real files: flattened PNG (focus baked) for images, the
        // decrypted movie for videos — via the shared CaptureDragPayload.
        // Dragging a tile that's part of the multi-selection brings the whole
        // selection along (standard Finder behavior).
        let sources = enclosingStripView()?.dragSources(anchoredAt: fileURL)
            ?? [CaptureDragPayload.Source(url: fileURL, displayName: displayName, isVideo: isVideo)]
        let exportable = sources.filter { CaptureDragPayload.canExport($0.url) }
        guard !exportable.isEmpty else {
            EditorToastView.show("Unlock to drag captures out", in: enclosingStripView() ?? self)
            return
        }

        let count = exportable.count
        let isMulti = count >= 2
        // Pick the writer strategy BEFORE rendering anything. Writers must be
        // HOMOGENEOUS: a drag that mixes file promises with plain file-URL items
        // drops the plain items (Finder keeps only the promises). Use promises for
        // a MULTI drag (every write lands post-drop, trackable for the "N of M"
        // progress sheet) or when an item can't be rendered eagerly at all
        // (encrypted video). `requiresPromise` is a manifest-only probe — it
        // never touches the payload.
        //
        // This USED to render every source eagerly first and infer the strategy
        // from which renders came back nil, which meant a multi-select rendered
        // each capture, threw the file away in favour of a promise, and left
        // Finder to render it a second time on drop — double work plus an
        // orphaned plaintext temp file per item.
        var usePromises = isMulti || exportable.contains { CaptureDragPayload.requiresPromise($0) }
        // Only a SINGLE eager item ever reaches here (usePromises covers multi),
        // so one render at most: a fast image PNG, an O(1) plaintext-video clone,
        // or a legacy file's own URL. It keeps the plain file URL because that
        // works where promises don't — Terminal path insert, canvas insert, and
        // apps that read only public.file-url. A render that unexpectedly fails
        // falls back to the promise path rather than dragging nothing.
        let eagerURL = usePromises ? nil : CaptureDragPayload.eagerFileURL(for: exportable[0])
        if !usePromises && eagerURL == nil { usePromises = true }
        // The progress sheet tracks every promise-written item; multi shows it
        // immediately ("N of M"), a single slow video keeps the grace delay.
        let session: DragExportSession? = usePromises
            ? DragExportSession(totalItems: count, host: window, immediate: isMulti) : nil

        let imageRect = NSRect(x: 0, y: bounds.maxY - thumbHeight, width: bounds.width, height: thumbHeight)
        let items = exportable.enumerated().map { index, source -> NSDraggingItem in
            let writer: NSPasteboardWriting
            if !usePromises, let eagerURL {
                // Single image keeps the fast eager file URL (Terminal path
                // insert, canvas insert). Finder COPIES it — the drag source's
                // out-of-app operation mask is `.copy` only, so it no longer
                // resolves as an alias. See draggingSession(sourceOperationMaskFor:).
                writer = eagerURL as NSURL
            } else {
                let dragItem = CaptureDragPayload.promiseItem(for: source, session: session)
                // The promise provider's delegate is WEAK — hold it until the
                // session ends or the drop dies silently (receiver never even
                // queries the filename).
                activeDragRetainers.append(dragItem.retainer)
                writer = dragItem.provider
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            // The grabbed tile shows its own thumbnail; companions cascade
            // behind it with theirs (falling back to the grabbed image).
            let tileImage = source.url == fileURL
                ? image
                : enclosingStripView()?.tileImage(for: source.url) ?? image
            let tileFrame = imageRect.offsetBy(dx: CGFloat(index) * 6,
                                               dy: CGFloat(index) * -6)
            if index == 0 {
                // Hint on the grabbed tile only — the cascading companions
                // behind it stay clean.
                let hinted = DragPeekHint.composed(for: tileImage, in: tileFrame)
                item.setDraggingFrame(hinted.frame, contents: hinted.image)
            } else {
                item.setDraggingFrame(tileFrame, contents: tileImage)
            }
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        // Walk up the view tree to find the owning RecentStripView.
        guard let strip = enclosingStripView() else {
            // Fallback if somehow detached: behave like a plain click.
            onSelect?(fileURL)
            return
        }

        let mods = event.modifierFlags.intersection([.command, .shift])
        if mods.contains(.shift) {
            strip.handleShiftClick(url: fileURL)
        } else if mods.contains(.command) {
            strip.handleCmdClick(url: fileURL)
        } else {
            // A video click always opens (switches to) the video; it auto-plays
            // only when the click lands on the play badge, else it opens paused.
            let onPlayBadge = playBadgeRect()?.contains(point) ?? false
            strip.handlePlainClick(url: fileURL, autoPlayVideo: onPlayBadge)
        }
    }

    /// The circular play-badge region on a video tile, in the tile's own
    /// coordinates — used to tell a "play" click from a "select" click. Matches
    /// the badge drawn in `draw`, grown a few points for a comfortable target.
    /// Nil for image tiles.
    private func playBadgeRect() -> NSRect? {
        guard isVideo else { return nil }
        let imageRect = NSRect(x: 0, y: bounds.maxY - thumbHeight,
                               width: bounds.width, height: thumbHeight)
        let badge = (thumbHeight * 0.34).rounded()
        return NSRect(x: imageRect.midX - badge / 2, y: imageRect.midY - badge / 2,
                      width: badge, height: badge).insetBy(dx: -4, dy: -4)
    }

    /// Walk up the view hierarchy looking for the parent RecentStripView.
    /// Returns nil if the thumbnail isn't currently inside one.
    private func enclosingStripView() -> RecentStripView? {
        var view: NSView? = self.superview
        while let v = view {
            if let strip = v as? RecentStripView { return strip }
            view = v.superview
        }
        return nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Out of app (Finder, Terminal): COPY only. Offering `.link` there let
        // Finder resolve a dragged file URL as an ALIAS (a broken ~1KB export)
        // instead of copying the real file. Within-app drops (canvas insert,
        // sidebar collections) keep the full set.
        context == .outsideApplication ? .copy : [.copy, .link, .generic]
    }

    /// Modifiers must not change what a drop DOES. macOS reserves ⌃ during a
    /// drag to mean "make a link", filtering the source mask down to `.link`
    /// at the drop — and the out-of-app mask here is deliberately `.copy`
    /// only, so a ⌃-drop resolved to NO operation and Finder bounced the
    /// drag. ⌃ is Sealshot's hide-the-window key, held through the drop by
    /// design: the drag hint itself tells the user to press it.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        DragPeekController.shared.begin(hiding: window)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // Runs on drop, refusal AND Esc alike — only `operation` differs — so
        // the window comes back on every path without Esc-specific handling.
        DragPeekController.shared.end()
    }

    /// Promise-delegate lifelines for the in-flight drag (see mouseDragged).
    /// NOT cleared in draggingSession(_:endedAt:) — the promise write happens
    /// AFTER the session ends (the receiver resolves it asynchronously), so
    /// releasing there would kill the weak delegate mid-write. Cleared on the
    /// NEXT drag; at most one drag's delegates linger (tiny, idle objects).
    var activeDragRetainers: [AnyObject] = []
}

/// Document-view container that turns a click-drag on its empty regions into
/// a marquee (rubber-band) selection. It holds the tile stack and fills the
/// viewport width, so the empty area past the last tile is draggable too.
///
/// `hitTest` routes empty regions (the stack's gaps AND the container's own
/// area) to the container while letting thumbnails keep their own clicks and
/// drag-out-to-Finder — the "empty-space only" rule, with no drag conflict.
/// A small distance threshold keeps a plain click a non-drag; that click
/// clears the selection. Geometry/selection math lives in `MarqueeSelection`.
final class MarqueeView: NSView {
    weak var stackView: NSView?

    /// `additive` = a ⌘/⇧ drag (add to existing); false = plain (replace).
    var onMarqueeBegin: ((_ additive: Bool) -> Void)?
    var onMarqueeUpdate: ((CGRect) -> Void)?
    var onMarqueeEnd: (() -> Void)?
    /// A plain (non-drag, non-modifier) click on empty space.
    var onEmptyClick: (() -> Void)?
    /// Any mouse-down on empty strip space (before we know if it's a click or a
    /// drag) — used to mark the strip as the active surface for ⌘A.
    var onPress: (() -> Void)?

    private var anchor: CGPoint?
    private var active = false
    private var beganAdditive = false

    private lazy var bandLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.20).cgColor
        l.strokeColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.9).cgColor
        l.lineWidth = 1
        l.zPosition = 1000   // draw above the thumbnail subviews
        return l
    }()

    /// Claim empty regions for marquee; hand thumbnails (and their descendants)
    /// back so they keep their own mouse handling.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self || hit === stackView { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
        anchor = convert(event.locationInWindow, from: nil)
        active = false
        beganAdditive = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.shift)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !active {
            guard MarqueeSelection.exceedsDragThreshold(anchor, point) else { return }
            active = true
            wantsLayer = true
            if bandLayer.superlayer == nil { layer?.addSublayer(bandLayer) }
            onMarqueeBegin?(beganAdditive)
        }
        let rect = MarqueeSelection.rect(from: anchor, to: point)
        bandLayer.path = CGPath(rect: rect, transform: nil)
        onMarqueeUpdate?(rect)
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil; active = false }
        if active {
            bandLayer.path = nil
            onMarqueeEnd?()
        } else if !beganAdditive {
            // A plain click on empty space clears the selection.
            onEmptyClick?()
        }
    }
}

