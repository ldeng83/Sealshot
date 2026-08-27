import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "library")

/// Trim a user-entered title; nil when it's blank (clears the override so the
/// filename shows).
func sanitizedUserTitle(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

enum LibraryViewMode: String, CaseIterable { case grid, list }

/// Fixed pixel widths for the list view's trailing columns so the sticky
/// header and every row align. Comfortable density (the only density).
enum LibraryListColumns {
    static let kindIcon: CGFloat = 16
    static let thumb: CGFloat = 56
    static let app: CGFloat = 90
    static let dimensions: CGFloat = 76
    static let size: CGFloat = 62
    static let date: CGFloat = 96
    static let star: CGFloat = 22
    static let rowSpacing: CGFloat = 12
}

/// Pure display formatting for list cells (unit-tested).
enum LibraryListFormatting {
    /// "W × H", or nil when either dimension is unknown (0).
    static func dimensions(_ w: Int, _ h: Int) -> String? {
        (w > 0 && h > 0) ? "\(w) × \(h)" : nil
    }
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Accent color for a capture's triage status dot in the list row.
func statusColor(_ status: CaptureStatus) -> Color {
    switch status {
    case .new: return .accentColor
    case .reviewed: return .green
    case .archived: return .gray
    }
}

/// Localized full month name (1 = January …) for the date organizer tree.
private let libraryMonthNames: [String] = Calendar.current.monthSymbols
private func libraryMonthName(_ m: Int) -> String {
    (m >= 1 && m <= 12) ? libraryMonthNames[m - 1] : "\(m)"
}

/// Shift-click range selection for the Library, mirroring the editor strip:
/// the inclusive span from `anchor` to `target` in display `order`. Falls back
/// to just `target` when there's no usable anchor (none set, or not listed).
func librarySelectionRange(from anchor: URL?, to target: URL, in order: [URL]) -> Set<URL> {
    guard let anchor,
          let a = order.firstIndex(of: anchor),
          let b = order.firstIndex(of: target) else { return [target] }
    let range = a <= b ? a...b : b...a
    return Set(order[range])
}

/// Shift-click extension for the Library: the anchor→target span unioned with
/// the `floor` — the items that must survive the extension (a prior marquee or
/// ⌘-click set). This is what lets a ⇧-click after a marquee "continue" the
/// block instead of collapsing to a bare range; the floor stays fixed across
/// successive ⇧-clicks so they can still shrink relative to one another.
func libraryExtendedSelection(from anchor: URL?, to target: URL,
                              in order: [URL], floor: Set<URL>) -> Set<URL> {
    librarySelectionRange(from: anchor, to: target, in: order).union(floor)
}

/// Section label for a capture date relative to `now`: Today (same calendar
/// day), Last 7 days (within the recents window), else Earlier.
func libraryDateSection(for date: Date, now: Date) -> String {
    if Calendar.current.isDate(date, inSameDayAs: now) { return "Today" }
    let cutoff = now.addingTimeInterval(-Double(libraryRecentsWindowDays) * 86_400)
    return date >= cutoff ? "Last 7 days" : "Earlier"
}

/// Group items into date sections, preserving item order within each section
/// and the fixed section order Today → Last 7 days → Earlier. Empty sections
/// are omitted.
func groupedByDate(_ items: [LibraryItem], now: Date) -> [(label: String, items: [LibraryItem])] {
    let order = ["Today", "Last 7 days", "Earlier"]
    var buckets: [String: [LibraryItem]] = [:]
    for item in items { buckets[libraryDateSection(for: item.modified, now: now), default: []].append(item) }
    return order.compactMap { label in
        guard let group = buckets[label], !group.isEmpty else { return nil }
        return (label, group)
    }
}

/// Tiny reference-type wrapper around a NotificationCenter observer token.
/// Used by `LibraryViewModel` so `deinit` (nonisolated) can release the token
/// without needing to access @MainActor-isolated stored properties.
private final class ObserverBox {
    var observer: NSObjectProtocol?
    init(_ observer: NSObjectProtocol?) { self.observer = observer }
}

/// Owns Library state and actions. Created by EditorWindowController, which
/// calls `reload()` whenever the Library tab is shown.
@MainActor
@Observable
final class LibraryViewModel {
    var section: LibrarySection = .allFiles {
        didSet {
            // Sections are the mutually-exclusive primary scope: switching to a
            // non-collections section clears any active collection/Favorites
            // selection (this is the "one click back to All Files" behavior).
            if section != .collections { collectionSelection = .none }
            reload()
        }
    }
    var searchText: String = "" { didSet { aiExpandedTerms = nil; scheduleSearchReload() } }
    /// AI-expanded keywords from the last submitted (Return) search; nil means a
    /// plain literal search. Cleared whenever the text changes.
    private var aiExpandedTerms: [String]?
    /// Grid sort, persisted across launches; changing it re-queries.
    var sort: LibrarySort = LibrarySortPreference.load() {
        didSet {
            guard sort != oldValue else { return }
            LibrarySortPreference.store(sort)
            reload()
        }
    }
    /// Grid vs list, persisted across launches (shared by every tab).
    var viewMode: LibraryViewMode = LibraryViewModePreference.load() {
        didSet {
            guard viewMode != oldValue else { return }
            LibraryViewModePreference.store(viewMode)
        }
    }
    /// Grid tile width (the adaptive grid item's minimum), persisted across
    /// launches and shared by every tab. Changing it only reflows the grid —
    /// no re-query, unlike `sort`.
    var tileWidth: CGFloat = LibraryTileSizePreference.load() {
        didSet {
            guard tileWidth != oldValue else { return }
            LibraryTileSizePreference.store(tileWidth)
        }
    }

    /// ⌘+scroll over the grid resizes tiles. Precise (trackpad) deltas are tiny
    /// and frequent; notched wheels are coarse — scale each so both feel similar.
    /// Scroll up → larger tiles. Clamped to the slider's range.
    func nudgeTileWidth(scrollDeltaY: CGFloat, precise: Bool) {
        let factor: CGFloat = precise ? 0.6 : 8.0
        let raw = tileWidth + scrollDeltaY * factor
        tileWidth = Swift.min(Swift.max(raw, LibraryTileSize.min), LibraryTileSize.max)
    }
    /// Width of the left nav sidebar, resized by dragging the divider. Persisted
    /// on drag-end via `LibrarySidebarWidthPreference` (clamped on load).
    var sidebarWidth: CGFloat = LibrarySidebarWidthPreference.load()
    var selection: Set<URL> = []
    /// True while the Library Quick Look preview overlay is showing. The overlay
    /// always renders the current single selection, so navigation reuses
    /// `moveSelection` and activation reuses `activate`.
    var quickLookOpen: Bool = false
    /// The panel presenter's active loader while the overlay is up — the Space
    /// handler routes play/pause through it for video previews. Weak + ignored:
    /// the presenter's coordinator owns the loader; this is only a key route.
    @ObservationIgnored weak var quickLookLoader: QuickLookPreviewLoader?
    /// The item a shift-click ranges from — the last plainly-clicked (or
    /// arrow-navigated) item, mirroring the editor strip's anchor.
    private(set) var anchorURL: URL?
    /// The selection a ⇧-click extension must preserve — the block that existed
    /// before the shift sequence (a marquee, a ⌘-click set, or a single click).
    /// Every selection-defining action refreshes it; `selectRange` unions onto
    /// it but leaves it fixed, so successive ⇧-clicks can still shrink.
    private(set) var shiftSelectionFloor: Set<URL> = []
    /// Canonical path keys of captures to outline (delete/restore and their
    /// undo/redo). Persistent until a click lands outside the set.
    private(set) var highlightedKeys: Set<String> = []
    /// The section+search-filtered, sorted set produced by `reload()`. The grid
    /// shows `items` (this, narrowed by the active date filter); the date tree's
    /// facets derive from this (before the date filter).
    private(set) var sectionItems: [LibraryItem] = [] {
        didSet { sectionItemsGeneration += 1 }
    }
    /// Baseline count for the current section, ignoring search + filters. Drives
    /// the Info section's "N of M" readout. Refreshed on every reload.
    private(set) var sectionTotalCount: Int = 0
    /// Whether the sidebar's Locked Archive row should be shown — refreshed on
    /// the same cadence as `reload()` (a cheap FileManager check, no manifest
    /// reads). False until the first reload runs.
    private(set) var hasLockedArchive: Bool = false
    /// Sidebar gate for the Scratch row, refreshed with every reload.
    private(set) var hasScratchItems: Bool = false
    /// Whether captures are currently bypassing the Library — the mode that
    /// makes an EMPTY Scratch row worth showing. Read at reload time; entering
    /// the Library tab always reloads, so a Settings round-trip refreshes it.
    private(set) var scratchModeOn: Bool = false
    var showScratchSection: Bool { hasScratchItems || scratchModeOn }
    /// Bytes waiting in Scratch, refreshed with every reload.
    private(set) var scratchBytes: Int64 = 0
    /// Bytes in the library proper and in the trash. Summed from the index
    /// (see `LibraryIndexStore.totalBytes`), so showing them costs a query.
    private(set) var allFilesBytes: Int64 = 0
    private(set) var trashBytes: Int64 = 0

    /// Formatted for a sidebar row; nil when empty (no "Zero KB" noise).
    func sizeLabel(for section: LibrarySection) -> String? {
        let bytes: Int64
        switch section {
        case .allFiles: bytes = allFilesBytes
        case .trash:    bytes = trashBytes
        case .scratch:  bytes = scratchBytes
        case .recents, .collections, .lockedArchive: bytes = 0
        }
        return Self.sizeLabel(bytes: bytes, for: section)
    }

    /// The rule, separated from the state so it can be tested: only sections
    /// that OWN their files carry a size. Recents is a WINDOW onto All Files
    /// and Collections overlap each other — a size on either would be
    /// double-counting dressed up as information.
    static func sizeLabel(bytes: Int64, for section: LibrarySection) -> String? {
        switch section {
        case .recents, .collections, .lockedArchive: return nil
        case .allFiles, .trash, .scratch:
            guard bytes > 0 else { return nil }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }
    var scratchSizeLabel: String? { sizeLabel(for: .scratch) }
    /// Whether the archive holds at least one restorable keystore seed —
    /// mirrors the Settings row's own check (`LockedArchiveRestore.status`).
    /// `Locked-Unrecoverable/` also holds disable-time quarantine content
    /// (no seed archived, never restorable — see `EncryptionProvisioner.
    /// disable`), so `hasLockedArchive` alone can't tell the banner whether
    /// Restore… would ever do anything. Refreshed alongside `hasLockedArchive`.
    private(set) var archiveHasKeystore: Bool = false

    /// Active date narrowing for the grid (session-only). Composes with section + search.
    var dateFilter: LibraryDateFilter = .none
    /// Active media-kind narrowing for the grid (session-only). Composes with
    /// section + search + date. Replaces the old Images/Videos sections.
    var fileTypeFilter: LibraryFileTypeFilter = .all
    /// Active collection narrowing for the grid (session-only). Composes with
    /// section + search + date + workflow. `.none` = show all; `.favorites` = starred
    /// only; `.collection(id)` = members of that collection.
    var collectionSelection: LibraryCollectionSelection = .none
    /// BY TAG facet: the tags whose rows are checked (AND filter), the facet's
    /// expand state, and the full alphabetical tag vocabulary with counts.
    var selectedTags: Set<String> = []
    var isTagsExpanded = false
    var libraryTags: [(tag: String, count: Int)] = []
    /// Accordion state: at most one year and one month expanded at a time.
    var expandedYear: Int?
    var expandedMonth: Int?

    /// Grid items: `sectionItems` narrowed by the active date, file-type, and
    /// collection filters. `@Observable` tracks all the inputs (they are read
    /// unconditionally below, cache hit or miss), so the grid updates when any
    /// changes.
    ///
    /// Memoized: this property is hit from many per-interaction paths (row
    /// renders, selection helpers, `item(for:)`), and re-filtering the whole
    /// section per access made multi-select O(selected × N).
    var items: [LibraryItem] {
        let key = ItemsCacheKey(
            generation: sectionItemsGeneration,
            dateFilter: dateFilter,
            // Date-relative buckets (Today / Last 7 days) shift at midnight;
            // keying on the current day keeps a long-running app honest.
            day: dateFilter == .none ? .distantPast : Calendar.current.startOfDay(for: Date()),
            fileType: fileTypeFilter,
            collection: collectionSelection,
            tags: selectedTags)
        if key == itemsCacheKey, let cached = itemsCache { return cached }
        let now = Date()
        var result = sectionItems
        if dateFilter != .none {
            result = result.filter { matchesDateFilter($0, dateFilter, calendar: .current, now: now) }
        }
        result = result.filter { fileTypeFilter.matches(isVideo: $0.isVideo) }
        result = result.filter { collectionSelection.matches(isFavorite: $0.isFavorite, collectionIDs: $0.collectionIDs) }
        if !selectedTags.isEmpty {
            result = result.filter { libraryItemMatchesTags(itemTags: $0.tags, selected: selectedTags) }
        }
        itemsCacheKey = key
        itemsCache = result
        itemsByURL = Dictionary(result.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        return result
    }

    private struct ItemsCacheKey: Equatable {
        var generation: Int
        var dateFilter: LibraryDateFilter
        var day: Date
        var fileType: LibraryFileTypeFilter
        var collection: LibraryCollectionSelection
        var tags: Set<String>
    }
    /// Bumped whenever `sectionItems` is replaced — the cache key's proxy for
    /// array identity (comparing the arrays themselves would defeat the point).
    private var sectionItemsGeneration = 0
    @ObservationIgnored private var itemsCacheKey: ItemsCacheKey?
    @ObservationIgnored private var itemsCache: [LibraryItem]?
    @ObservationIgnored private var itemsByURL: [URL: LibraryItem] = [:]

    /// Year/month/day facets for the sidebar tree (counts EXCLUDE the date filter).
    var dateFacets: LibraryDateFacets {
        libraryDateFacets(sectionItems, calendar: .current, now: Date())
    }

    /// Pick a date bucket; clicking the active one again clears the filter.
    func selectDate(_ filter: LibraryDateFilter) {
        dateFilter = (dateFilter == filter) ? .none : filter
        clearSelection()
    }
    /// Toggle a tag in the AND filter (clears grid selection like date/collection).
    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
        clearSelection()
    }
    /// Clear the whole tag filter.
    func clearTagFilter() {
        guard !selectedTags.isEmpty else { return }
        selectedTags.removeAll()
        clearSelection()
    }

    /// Any filter that narrows the view is active — the section scope
    /// (Recents/Collections/Trash vs the default All Files) plus search, file
    /// type, date, and tags.
    var hasActiveFilter: Bool {
        section != .allFiles || !searchText.isEmpty || fileTypeFilter != .all
            || dateFilter != .none || !selectedTags.isEmpty
    }

    /// Label for the section/scope chip: the specific collection's name (or
    /// Favorites) when one is selected, else the section title. nil at the
    /// default All Files (no chip).
    var sectionChipLabel: String? {
        switch section {
        case .allFiles:                       return nil
        case .recents, .scratch, .trash, .lockedArchive: return section.title
        case .collections:
            switch collectionSelection {
            case .favorites:          return "Favorites"
            case .collection(let id): return sidebarCollections.first { $0.collectionID == id }?.name ?? "Collection"
            case .none:               return "Collections"
            }
        }
    }

    /// Reset every filter back to its default in one step — including the
    /// section scope, so the view returns to All Files.
    func clearAllFilters() {
        if section != .allFiles { section = .allFiles }   // didSet also clears the collection
        if !searchText.isEmpty { searchText = "" }
        if fileTypeFilter != .all { fileTypeFilter = .all }
        if dateFilter != .none { dateFilter = .none }
        if !selectedTags.isEmpty { selectedTags.removeAll() }
        clearSelection()
    }
    /// Expand a year (collapsing any other year + its open month); re-toggle collapses.
    func toggleYear(_ year: Int) {
        if expandedYear == year { expandedYear = nil; expandedMonth = nil }
        else { expandedYear = year; expandedMonth = nil }
    }
    /// Expand a month within the open year; re-toggle collapses.
    func toggleMonth(_ month: Int) {
        expandedMonth = (expandedMonth == month) ? nil : month
    }
    /// Live column count of the grid, written by the view as its width changes.
    /// Drives ↑/↓ row jumps in `moveSelection`; ignored in list mode (1 column).
    var gridColumns: Int = 1
    /// Explicit request to scroll a specific item into view. Set ONLY by
    /// programmatic reveal ("Show in Library") and keyboard navigation — a
    /// plain mouse selection leaves it nil so the grid doesn't auto-scroll.
    /// The view observes this, scrolls, then clears it back to nil.
    var scrollTarget: URL?
    /// Set by `duplicate(_:)`; the next `reload()` selects these once they land.
    private var pendingSelectAfterReload: Set<URL>?

    private let config: CaptureConfig
    /// SQLite-backed capture index; all Library disk I/O runs on this actor.
    private let store: LibraryIndexStore
    private let onOpen: (URL) -> Void
    /// Play a video `.seal` package inline in the editor canvas (replacing the
    /// old floating sheet). Wired by EditorWindowController to `playVideoInCanvas`.
    private let onPlayVideo: (_ url: URL) -> Void
    private let onCaptureNew: () -> Void
    private let onImport: () -> Void
    /// Shared with EditorWindowController so Library deletes land on the
    /// same ⌘Z timeline as strip deletes. Set right after construction.
    var globalUndo: GlobalUndoStore?
    /// Box holding the captureMetadataDidChange observer token so deinit
    /// (nonisolated) can release it without accessing @MainActor properties.
    private let metadataObserverBox: ObserverBox
    /// Observer token for the transient-highlight broadcast.
    private let highlightObserverBox: ObserverBox
    /// Observer token for the collections-changed broadcast (posted after an
    /// as-collection package import writes a new `CaptureCollection`).
    private let collectionsObserverBox: ObserverBox
    /// Observer token for the save-folder-changed broadcast (Settings pointed
    /// the app at a different library).
    private let saveFolderObserverBox: ObserverBox
    /// Latest-wins token: a background query that finishes after a newer one
    /// started must not clobber the newer results.
    private var reloadGeneration = 0
    private var searchDebounce: Task<Void, Never>?
    private var metadataReloadDebounce: Task<Void, Never>?

    // MARK: - per-item info (sidebar Info section)

    /// Loaded info for the single selected item (nil while none/multi selected or
    /// still loading). Reloaded when the selection changes or metadata is edited.
    private(set) var selectedInfo: LibraryItemInfo?
    /// The URL `selectedInfo` was last loaded for — so a same-item refresh
    /// (e.g. a favorite/tag edit) doesn't clear-and-flash the panel.
    private var selectedInfoURL: URL?
    private var infoLoadGeneration = 0
    private var infoLoadTask: Task<Void, Never>?

    /// Reload `selectedInfo` for the current selection. Called from every
    /// selection mutator and from the `.captureMetadataDidChange` handler so
    /// edits are reflected immediately.
    ///
    /// A 180 ms debounce prevents decrypting every intermediate item when the
    /// user holds an arrow key; the generation counter drops any task that
    /// races a later selection change.
    func refreshSelectedInfo() {
        infoLoadTask?.cancel()
        infoLoadGeneration += 1
        let generation = infoLoadGeneration
        guard selection.count == 1, let url = selection.first else {
            selectedInfo = nil; selectedInfoURL = nil; return
        }
        // Clear only when SWITCHING items (so B doesn't briefly show A's info).
        // A same-item refresh keeps the current info and swaps the reloaded
        // value in — no placeholder flash on favorite/tag edits.
        if url != selectedInfoURL { selectedInfo = nil }
        selectedInfoURL = url
        infoLoadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled, generation == self.infoLoadGeneration else { return }
            // A recording saved as a plain movie has no manifest — derive what
            // the file itself can tell us (duration, pixel size, bytes, dates)
            // rather than leaving the panel empty, which reads as a bug.
            var info: LibraryItemInfo?
            if plainMovieExtensions.contains(url.pathExtension.lowercased()) {
                let values = try? url.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                let probe = await PlainMovieProbe.read(url)
                guard generation == self.infoLoadGeneration else { return }
                info = LibraryItemInfo(
                    plainMovie: url,
                    name: CaptureDisplayName.resolve(for: url),
                    fileSize: Int64(values?.fileSize ?? 0),
                    durationSeconds: probe.durationSeconds,
                    pixelSize: probe.pixelSize,
                    created: values?.creationDate,
                    modified: values?.contentModificationDate)
            } else if let m = try? SealMetadataStore.readManifest(at: url) {
                let name = CaptureDisplayName.resolve(for: url)
                let size = sealPackageSize(at: url) ?? (self.item(for: url)?.fileSize ?? 0)
                info = LibraryItemInfo(manifest: m, name: name, fileSize: size)
            }
            guard generation == self.infoLoadGeneration else { return }
            self.selectedInfo = info
        }
    }

    init(config: CaptureConfig,
         store: LibraryIndexStore = .shared,
         onOpen: @escaping (URL) -> Void,
         onPlayVideo: @escaping (_ url: URL) -> Void = { _ in },
         onCaptureNew: @escaping () -> Void,
         onImport: @escaping () -> Void = {}) {
        self.config = config
        self.store = store
        self.onOpen = onOpen
        self.onPlayVideo = onPlayVideo
        self.onCaptureNew = onCaptureNew
        self.onImport = onImport
        // Register a placeholder box first so `self` is fully initialized.
        // The real observer closure captures the box by reference (it's a
        // class), so the box written into metadataObserverBox IS the one
        // the closure holds — there's no double-retain/mismatch.
        // Initialize all stored observer boxes BEFORE capturing `self` in any
        // notification closure (Swift forbids referencing self — even weakly —
        // until every stored property is set).
        let box = ObserverBox(nil)
        self.metadataObserverBox = box
        let highlightBox = ObserverBox(nil)
        self.highlightObserverBox = highlightBox
        let collectionsBox = ObserverBox(nil)
        self.collectionsObserverBox = collectionsBox
        let saveFolderObserverBox = ObserverBox(nil)
        self.saveFolderObserverBox = saveFolderObserverBox

        box.observer = NotificationCenter.default.addObserver(
            forName: .captureMetadataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleMetadataReload()
                self?.refreshSelectedInfo()
            }
        }
        highlightBox.observer = NotificationCenter.default.addObserver(
            forName: ActivityHighlightStore.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.highlightedKeys = ActivityHighlightStore.shared.keys }
        }
        // The library moved. Every query reads `config.saveFolder` fresh, so a
        // reload is enough to re-point — but the SELECTION isn't: it holds URLs
        // under the old folder, which would leave the Info panel describing a
        // capture that is no longer in the library.
        saveFolderObserverBox.observer = NotificationCenter.default.addObserver(
            forName: .saveFolderDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearSelection()
                self.collectionStore = nil
                self.reload()
            }
        }
        collectionsBox.observer = NotificationCenter.default.addObserver(
            forName: .collectionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Drop the cached store so the next read re-loads the freshly
                // written collections.sealed from disk, then refresh.
                self?.collectionStore = nil
                self?.reload()
            }
        }
        // Pick up any marks that accumulated before this (lazily created) view
        // model existed — the whole point of the shared store.
        highlightedKeys = ActivityHighlightStore.shared.keys
    }

    deinit {
        if let obs = metadataObserverBox.observer {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = highlightObserverBox.observer {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = collectionsObserverBox.observer {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = saveFolderObserverBox.observer {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Dismiss the delete/restore highlight when a click lands outside the
    /// marked set. Delegates to the shared store, which clears it everywhere
    /// (strips + Library) and notifies; the observer mirrors it back here.
    func dismissHighlight(clicked: URL?) {
        ActivityHighlightStore.shared.dismiss(clicked: clicked)
    }

    /// Query the index for the current section/search. All disk I/O
    /// (stat scan, manifest reads for changed files, SQLite) happens on the
    /// store actor; results land back here latest-wins. Drops any selection
    /// whose file no longer exists.
    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let saveFolder = config.saveFolder
        // Cheap stat-level check, refreshed alongside every reload so the
        // sidebar row appears/disappears in step with the section it gates.
        hasLockedArchive = LockedArchivePresence.hasItems(saveFolder: saveFolder)
        hasScratchItems = ScratchPresence.hasItems(saveFolder: saveFolder)
        // Either mode being on makes an empty Scratch row worth showing — it
        // is the standing answer to "where do my captures/recordings go now".
        let prefs = ScratchCapturePreference()
        scratchModeOn = !prefs.addsToLibrary || !prefs.recordingsAddToLibrary
        scratchBytes = ScratchCapture.totalSize(in: saveFolder)
        let sizeStore = store
        // The section being loaded gets reconciled by `items(section:)` below;
        // the other one needs its own pass or its size stays 0 until visited.
        let loadedFolder = libraryFolder(for: section, saveFolder: saveFolder)
        let needsAll = libraryFolder(for: .allFiles, saveFolder: saveFolder) != loadedFolder
        let needsTrash = libraryFolder(for: .trash, saveFolder: saveFolder) != loadedFolder
        Task { [weak self] in
            let all = await sizeStore.totalBytes(section: .allFiles, saveFolder: saveFolder,
                                                 reconcileFirst: needsAll)
            let trash = await sizeStore.totalBytes(section: .trash, saveFolder: saveFolder,
                                                   reconcileFirst: needsTrash)
            guard let self, generation == self.reloadGeneration else { return }
            self.allFilesBytes = all
            self.trashBytes = trash
        }
        archiveHasKeystore = LockedArchiveRestore.status(saveFolder: saveFolder).hasKeystore
        // If the archive emptied while it was the active section (restore, or
        // manual cleanup in Finder), fall back to All Files — the sidebar row
        // is gone, so staying here would strand the user on a hidden section.
        if self.section.isLockedArchive, !hasLockedArchive {
            self.section = .allFiles
        }
        // Same stranding rule — but against the ROW's visibility, not bare
        // contents: with the toggle off, an emptied Scratch section stays put,
        // exactly as an emptied Trash does.
        if self.section.isScratch, !showScratchSection {
            self.section = .allFiles
        }
        let section = self.section
        let search = self.searchText
        let sort = self.sort
        let expanded = self.aiExpandedTerms
        Task {
            // Unified index: video .seal packages are recognized by captureKind
            // in the index; the section type filter is applied inside makeLibraryItems.
            let items = await store.items(section: section, saveFolder: saveFolder,
                                          search: search, now: Date(), sort: sort,
                                          expandedTerms: expanded)
            guard generation == reloadGeneration else { return }
            self.sectionItems = items
            let live = Set(items.map { $0.url })
            selection = selection.intersection(live)
            shiftSelectionFloor = shiftSelectionFloor.intersection(live)
            if let pending = pendingSelectAfterReload {
                pendingSelectAfterReload = nil
                let landed = pending.intersection(live)
                if !landed.isEmpty {
                    selection = landed
                    shiftSelectionFloor = landed
                    scrollTarget = landed.first   // reveal a freshly-made copy
                }
            }
            self.refreshSelectedInfo()
            if self.searchText.isEmpty {
                self.sectionTotalCount = items.count    // no search → items IS the total
            } else {
                let total = await self.store.sectionTotalCount(section: section, saveFolder: saveFolder)
                guard generation == self.reloadGeneration else { return }
                self.sectionTotalCount = total
            }
            // Refresh the tag vocabulary so the BY TAG facet tracks adds/removes.
            let freshTags = await self.store.allTags()
            guard generation == self.reloadGeneration else { return }
            self.libraryTags = sortedTagsAlphabetically(freshTags)
            // Drop any selected tags that no longer exist.
            self.selectedTags.formIntersection(Set(self.libraryTags.map { $0.tag }))
            // Counts are derived from `items`; refresh the (cheap) collection
            // snapshot so the sidebar tallies track the freshly-loaded section.
            await self.reloadCollections()
        }
    }

    // MARK: - Collections

    /// Cached snapshot of the durable collection list (names + order). Rendered
    /// by the sidebar; refreshed by `reloadCollections()`.
    private(set) var collections: [CaptureCollection] = []
    /// A user-visible persistence error from create/rename/delete. Read failures
    /// while the whole library is locked remain represented by the lock UI.
    private(set) var collectionOperationError: String?
    /// Lazily built in the current security mode: plaintext JSON while enhanced
    /// security is off, sealed storage while it is on and unlocked.
    private var collectionStore: CollectionStore?

    private func ensureCollectionStore() throws -> CollectionStore {
        if let s = collectionStore { return s }
        let s = try CollectionStore.openCurrentLibraryStore()
        collectionStore = s
        return s
    }

    private func reportCollectionOperationError(_ error: Error) {
        collectionOperationError = "Sealshot couldn’t save the collection. \(error.localizedDescription)"
        os_log("collection operation failed: %{public}@", log: log, type: .error,
               String(describing: error))
    }

    func clearCollectionOperationError() {
        collectionOperationError = nil
    }

    /// Refresh the cached collection snapshot from the store (or clear it when
    /// the library is locked / unavailable).
    func reloadCollections() async {
        do {
            let store = try ensureCollectionStore()
            collections = await store.all()
        } catch {
            collections = []
        }
    }

    func createCollection(name: String) async {
        do {
            _ = try await ensureCollectionStore().create(name: name, now: Date())
            collectionOperationError = nil
            await reloadCollections()
        } catch {
            reportCollectionOperationError(error)
        }
    }

    func renameCollection(id: UUID, to name: String) async {
        do {
            try await ensureCollectionStore().rename(id: id, to: name)
            collectionOperationError = nil
            await reloadCollections()
        } catch {
            reportCollectionOperationError(error)
        }
    }

    /// Every member URL of `id`, resolved from the FULL index (not just the
    /// loaded section) — so "delete the collection's media" reaches members that
    /// are filtered out of / not yet loaded into the current view.
    func allCollectionMemberURLs(_ id: UUID) async -> [URL] {
        await store.collectionMembers(collectionID: id, saveFolder: config.saveFolder).map(\.url)
    }

    /// Delete a collection record.
    ///
    /// The collection record is committed first; if that fails, captures remain
    /// untouched. When `deleteMemberURLs` is non-nil, that media is then moved to
    /// Trash (undoable, whole-collection scope). Otherwise the captures remain
    /// and their membership is pruned best-effort. Captures outside the loaded
    /// section can retain the deleted id as a harmless orphan — counts ignore
    /// unknown collection ids, so the UI never surfaces it.
    func deleteCollection(id: UUID, deleteMemberURLs: [URL]? = nil) async {
        do {
            try await ensureCollectionStore().delete(id: id)
            collectionOperationError = nil
        } catch {
            reportCollectionOperationError(error)
            return
        }
        if let deleteMemberURLs, !deleteMemberURLs.isEmpty {
            // Move the collection's media to Trash (undoable via `delete`). The
            // trashed .seal keeps the now-deleted collection id in its metadata,
            // a harmless orphan that restore-on-undo tolerates.
            delete(deleteMemberURLs)
        } else {
            // Prune membership from visible members before deleting the record.
            // Iterate sectionItems directly so archived/filtered-out captures are
            // included and we read the membership from the item itself (not from
            // item(for:), which only searches the post-filter list and would
            // return nil for hidden members, wiping their collection membership).
            for member in sectionItems where member.collectionIDs.contains(id) {
                try? SealMetadataStore.setCollections(member.collectionIDs.filter { $0 != id }, to: member.url)
            }
        }
        if case .collection(let activeID) = collectionSelection, activeID == id { collectionSelection = .none }
        reload() // reload() already awaits reloadCollections() internally
    }

    /// Member tally per collection across the currently-loaded section rows.
    /// (Only counts known collections so a stale membership id never shows.)
    var collectionCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        let known = Set(collections.map(\.id))
        for item in sectionItems {
            for cid in item.collectionIDs where known.contains(cid) {
                counts[cid, default: 0] += 1
            }
        }
        return counts
    }

    /// Select a collection as the active grid filter. The date and section filters
    /// are left in place so the collection composes with them (e.g. "Invoices from 2026").
    /// Self-enforces `section = .collections` so callers don't need to set it separately.
    func selectCollection(_ id: UUID) {
        section = .collections
        // Clicking the already-selected collection is a no-op (it stays
        // selected) — deselect by choosing Collections root or another section.
        collectionSelection = .collection(id)
        clearSelection()
    }

    /// Select the built-in Favorites filter. Clicking it again is a no-op (stays
    /// selected) — deselect via Collections root or another section.
    /// Self-enforces `section = .collections` so callers don't need to set it separately.
    func selectFavorites() {
        section = .collections
        collectionSelection = .favorites
        clearSelection()
    }

    /// True when the content area should show the album-browser tile grid
    /// (Collections section + no specific collection selected).
    var isAlbumBrowser: Bool {
        section == .collections && collectionSelection == .none
    }

    /// Content-view title: shows the open collection/Favorites name instead of
    /// the generic "Collections" label when a specific filter is active.
    var contentTitle: String {
        switch collectionSelection {
        case .favorites: return "Favorites"
        case .collection(let id): return collections.first { $0.id == id }?.name ?? section.title
        case .none: return section.title
        }
    }

    /// Sidebar disclosure state for the Collections group (collapsed by default).
    var isCollectionsExpanded = false

    /// Select the Collections root (the album browser, `.none` collection filter).
    func selectCollectionsRoot() {
        section = .collections
        collectionSelection = .none
        clearSelection()
    }

    /// One sidebar row under the expandable Collections group: the pinned
    /// Favorites pseudo-collection first, then each manual collection.
    struct SidebarCollection: Identifiable {
        let id: String
        let name: String
        let count: Int
        let isFavorites: Bool
        let collectionID: UUID?
    }

    /// Rows shown when the Collections group is expanded. Favorites is pinned
    /// first (count from `sectionItems` favorites, mirroring `collectionCounts`'
    /// section-scoped baseline — a library-wide favorite count is a later
    /// refinement), then the manual collections with their member tallies.
    var sidebarCollections: [SidebarCollection] {
        let favCount = sectionItems.filter(\.isFavorite).count
        var rows = [SidebarCollection(id: "favorites", name: "Favorites", count: favCount,
                                      isFavorites: true, collectionID: nil)]
        rows += collections.map {
            SidebarCollection(id: $0.id.uuidString, name: $0.name,
                              count: collectionCounts[$0.id] ?? 0,
                              isFavorites: false, collectionID: $0.id)
        }
        return rows
    }

    /// Play a video `.seal` package inline in the editor canvas.
    func play(_ item: LibraryItem) {
        onPlayVideo(item.url)
    }

    /// Header sort-menu action: choosing the active field flips its direction;
    /// a new field switches to it at its natural direction.
    func chooseSort(_ field: LibrarySortField) {
        if sort.field == field {
            sort.direction = sort.direction == .ascending ? .descending : .ascending
        } else {
            sort = LibrarySort(field: field, direction: field.defaultDirection)
        }
    }

    /// Coalesce bursts of `.captureMetadataDidChange` into a single reload. A
    /// multi-file import posts one per file as its async metadata (and possible
    /// title-rename) lands; reloading per file would resettle the grid each time
    /// (the renamed file's URL — the equal-date tie-break key — changes). One
    /// trailing reload lets the grid settle once, after the burst quiets.
    private func scheduleMetadataReload() {
        metadataReloadDebounce?.cancel()
        metadataReloadDebounce = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            reload()
        }
    }

    /// Search re-queries the index (FTS for OCR text) rather than filtering
    /// in memory; a short debounce keeps fast typing from queueing a reload
    /// per keystroke.
    private func scheduleSearchReload() {
        searchDebounce?.cancel()
        searchDebounce = Task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            reload()
        }
    }

    /// Return in the search field: when on-device AI is available and enabled,
    /// expand the query into related keywords (so related image text matches),
    /// then re-query. Otherwise it's a normal literal search.
    func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, AIAvailability.isFoundationModelAvailable,
              AIFeaturePreference().enabled else {
            reload()
            return
        }
        searchDebounce?.cancel()
        searchDebounce = Task { @MainActor in
            var terms: [String] = []
            if #available(macOS 26, *) {
                terms = await FoundationSearchExpander().expand(query: query)
            }
            guard !Task.isCancelled else { return }
            aiExpandedTerms = terms.isEmpty ? nil : terms
            reload()
        }
    }

    var subtitle: String {
        if isAlbumBrowser {
            let n = sidebarCollections.count
            return "\(n) collection\(n == 1 ? "" : "s")"
        }
        let n = items.count
        return "\(n) item\(n == 1 ? "" : "s") • Sorted by Date"
    }

    /// The folder used to locate and persist captures. Exposed so the Library
    /// view can pass it directly to maintenance jobs (e.g. visual-tag backfill).
    var saveFolder: URL { config.saveFolder }

    // MARK: selection
    func selectOnly(_ url: URL) {
        selection = [url]; anchorURL = url; shiftSelectionFloor = [url]; refreshSelectedInfo()
    }
    func toggle(_ url: URL) {
        if selection.contains(url) {
            selection.remove(url)
            if anchorURL == url { anchorURL = nil }
        } else {
            selection.insert(url)
            anchorURL = url
        }
        // A ⇧-click after cherry-picking with ⌘ extends from this set.
        shiftSelectionFloor = selection
        refreshSelectedInfo()
    }
    /// ⇧-click: extend the selection to the inclusive range from the anchor to
    /// `url` (in display order), unioned with the floor so a prior marquee or
    /// ⌘-click set is preserved rather than replaced. The anchor and floor stay
    /// put so successive ⇧-clicks rebase from the same origin — exactly like the
    /// editor strip, just additive over the block that was already selected.
    func selectRange(to url: URL) {
        selection = libraryExtendedSelection(from: anchorURL, to: url,
                                             in: items.map(\.url), floor: shiftSelectionFloor)
        if anchorURL == nil { anchorURL = url }
        refreshSelectedInfo()
    }
    /// A marquee drag just ended with `selection` set live. Record it as the
    /// floor and anchor a subsequent ⇧-click on the last item (in display order)
    /// of the block, so shift-clicking after a marquee extends it instead of
    /// collapsing to the clicked item.
    func finishMarquee() {
        shiftSelectionFloor = selection
        let order = items.map(\.url)
        anchorURL = order.last(where: { selection.contains($0) }) ?? anchorURL
        refreshSelectedInfo()
    }
    func clearSelection() { selection = []; anchorURL = nil; shiftSelectionFloor = []; refreshSelectedInfo() }

    /// Space in the Library toggles the Quick Look overlay. Opening with nothing
    /// selected previews the first item; opening a multi-selection previews the
    /// anchor. Delegates the decision to `QuickLookToggle` (unit-tested).
    /// Disabled in Locked Archive — locked packages can't be previewed.
    func toggleQuickLook() {
        guard !section.isLockedArchive else { return }
        let result = QuickLookToggle.resolve(
            currentlyOpen: quickLookOpen,
            selection: Array(selection),
            anchor: anchorURL,
            firstItem: items.first?.url)
        if let url = result.selectURL { selectOnly(url) }
        quickLookOpen = result.open
    }

    func closeQuickLook() {
        quickLookOpen = false
    }

    /// Context-menu "Preview": open the Quick Look overlay on `url` (selecting it
    /// first so the panel previews that item). Disabled in Locked Archive.
    func previewInQuickLook(_ url: URL) {
        guard !section.isLockedArchive else { return }
        selectOnly(url)
        quickLookOpen = true
    }

    // MARK: keyboard navigation

    /// Move the highlight by an arrow key (123 left, 124 right, 125 down, 126
    /// up). Replaces the selection with a single item; ↑/↓ jump a full row in
    /// grid mode (`gridColumns`) or one item in list mode. Clamps at the ends
    /// (no wrap). With nothing selected, the first arrow lands on item 0.
    /// Returns true if it consumed the key.
    @discardableResult
    func moveSelection(_ keyCode: UInt16) -> Bool {
        guard !items.isEmpty else { return false }
        let urls = items.map { $0.url }
        let cols = (viewMode == .grid) ? max(1, gridColumns) : 1

        guard let current = selection.first.flatMap({ urls.firstIndex(of: $0) }) else {
            selectSingle(urls[0])
            return true
        }

        let next: Int
        switch keyCode {
        case 123: next = max(0, current - 1)                  // left
        case 124: next = min(urls.count - 1, current + 1)     // right
        case 126: next = max(0, current - cols)               // up
        case 125: next = min(urls.count - 1, current + cols)  // down
        default:  return false
        }
        selectSingle(urls[next])
        return true
    }

    /// ⌘ + arrow: jump to the row/column extreme — ⌘← leftmost-in-row, ⌘→
    /// rightmost-in-row, ⌘↑ top-of-column, ⌘↓ bottom-of-column. In list mode
    /// (1 column) ↑/↓ jump to the first/last item and ←/→ stay put. Replaces the
    /// selection with a single item (no wrap). Returns true if it consumed the key.
    @discardableResult
    func moveSelectionToExtreme(_ keyCode: UInt16) -> Bool {
        guard !items.isEmpty else { return false }
        let urls = items.map { $0.url }
        let count = urls.count
        let cols = (viewMode == .grid) ? max(1, gridColumns) : 1

        guard let current = selection.first.flatMap({ urls.firstIndex(of: $0) }) else {
            selectSingle(urls[0])
            return true
        }

        let row = current / cols
        let col = current % cols
        let next: Int
        switch keyCode {
        case 123: next = row * cols                             // leftmost in row
        case 124: next = min(count - 1, row * cols + cols - 1)  // rightmost in row
        case 126: next = col                                   // top of column
        case 125:                                              // bottom of column
            var last = col
            while last + cols < count { last += cols }
            next = last
        default:  return false
        }
        guard next != current else { return true }   // already at the extreme; consume
        selectSingle(urls[next])
        return true
    }

    /// Replace the selection with a single item and keep it visible — the shared
    /// tail of the arrow-key navigators.
    private func selectSingle(_ url: URL) {
        selection = [url]
        anchorURL = url
        shiftSelectionFloor = [url]
        scrollTarget = url   // keyboard nav keeps the highlight visible
        refreshSelectedInfo()
    }

    /// ⌘A — select every item currently visible in the list, i.e. the fully
    /// post-filter `items` (section + search + date + file-type + collection +
    /// tags). No-op on an empty list, and at the album browser (Collections
    /// root) where the content area shows collection tiles, not captures — even
    /// though `items` there evaluates to the whole library. The anchor moves to
    /// the last item so a follow-up ⇧-click ranges sensibly.
    func selectAll() {
        guard !isAlbumBrowser else { return }
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        selection = Set(urls)
        anchorURL = urls.last
        shiftSelectionFloor = selection
        refreshSelectedInfo()
    }

    /// Open the highlighted item (single selection only). Returns true if it
    /// opened something.
    @discardableResult
    func openSelected() -> Bool {
        guard selection.count == 1, let url = selection.first,
              let item = items.first(where: { $0.url == url }) else { return false }
        activate(item)
        return true
    }

    /// Default action for an item: videos play in the sheet, images open in the
    /// editor. Locked Archive items can't be decrypted, so this is a no-op
    /// there — the section is visible-but-inert by design (see `isLockedArchive`),
    /// not an error to surface.
    func activate(_ item: LibraryItem) {
        guard !section.isLockedArchive else { return }
        quickLookOpen = false   // opening the editor / inline player dismisses the overlay
        if item.isVideo { play(item) } else { open(item.url) }
    }

    /// The item backing a URL, if currently listed (for menu/tap routing).
    func item(for url: URL) -> LibraryItem? {
        _ = items   // refresh the memoized cache (and itsByURL index) if stale
        return itemsByURL[url]
    }

    /// Map a set of selected URLs to export sources (skips unknown URLs).
    func exportSources(for urls: [URL]) -> [SharePackageSource] {
        urls.compactMap { url in
            guard let item = item(for: url) else { return nil }
            return SharePackageSource(url: item.url, displayName: item.displayName, isVideo: item.isVideo)
        }
    }

    /// Resolve every member of `collectionID` from the full index (not the loaded
    /// section) and map to export sources. Runs on the store actor.
    func collectionExportSources(collectionID: UUID) async -> [SharePackageSource] {
        let members = await store.collectionMembers(collectionID: collectionID,
                                                    saveFolder: config.saveFolder)
        return members.map {
            SharePackageSource(url: $0.url, displayName: $0.displayName, isVideo: $0.isVideo)
        }
    }

    /// Export sources for the Favorites facet (all favorited captures, full
    /// index). Favorites has no collection id, so it resolves by the favorite flag.
    func favoriteExportSources() async -> [SharePackageSource] {
        let members = await store.favoriteMembers(saveFolder: config.saveFolder)
        return members.map {
            SharePackageSource(url: $0.url, displayName: $0.displayName, isVideo: $0.isVideo)
        }
    }

    /// Export sources for the whole library (every capture, full index) — the
    /// "All Files" facet, for exporting the entire library as one package.
    func allExportSources() async -> [SharePackageSource] {
        let members = await store.allMembers(saveFolder: config.saveFolder)
        return members.map {
            SharePackageSource(url: $0.url, displayName: $0.displayName, isVideo: $0.isVideo)
        }
    }

    /// Row/column gap between grid tiles. Shared by the `LazyVGrid` and by
    /// `gridColumnCount` so arrow-key row jumps line up with what's on screen.
    static let gridSpacing: CGFloat = 22

    /// Number of columns an adaptive grid of `minimum: tileWidth` tiles fits
    /// into `width` (the grid's content width). Mirrors SwiftUI's adaptive
    /// layout so ↑/↓ row jumps line up with what's on screen.
    static func gridColumnCount(forWidth width: CGFloat,
                                tileWidth: CGFloat = LibraryTileSize.default) -> Int {
        let spacing = gridSpacing
        guard width > 0 else { return 1 }
        return max(1, Int((width + spacing) / (tileWidth + spacing)))
    }

    /// Move to the section that contains `url` (Trash if it lives under the
    /// Deleted folder, else All Shots), clear any search, and select it. The
    /// selection change scrolls the Library to the item. Used by the editor
    /// strip's "Show in Library".
    func reveal(_ url: URL) {
        searchText = ""
        let inTrash = url.deletingLastPathComponent().lastPathComponent
            == SealDeleter.deletedSubfolderName
        if ScratchCapture.isScratch(url) {
            section = .scratch
        } else {
            section = inTrash ? .trash : .allFiles   // didSet reloads + refilters
        }
        selection = [url]
        anchorURL = url
        shiftSelectionFloor = [url]
        scrollTarget = url                       // reveal always scrolls into view
    }

    /// Batch reveal (drop-to-import): select the whole set, scroll to first.
    func reveal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        reveal(first)
        guard urls.count > 1 else { return }
        selection = Set(urls)
        shiftSelectionFloor = selection
    }

    // MARK: actions
    func captureNew() { onCaptureNew() }
    func importNew() { onImport() }
    func open(_ url: URL) { onOpen(url) }

    /// The library folder itself, for Finder-first file management.
    func openLibraryFolderInFinder() {
        let folder = config.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func showInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Keep scratch captures: move each into the Library and announce it the
    /// way a fresh capture is announced, so the index, strips, and ⌘Z pick the
    /// file up as new. Selection follows the moved files into All Files.
    func addToLibrary(_ urls: [URL]) {
        var moved: [URL] = []
        for url in urls where ScratchCapture.isScratch(url) {
            do {
                moved.append(try ScratchCapture.keep(url, saveFolder: config.saveFolder))
            } catch {
                os_log("scratch keep failed: %{public}@", log: log, type: .error,
                       String(describing: error))
            }
        }
        guard !moved.isEmpty else { return }
        NotificationCenter.default.post(name: .captureFilesImported, object: moved,
                                        userInfo: ["kind": "capture"])
        reveal(moved)
    }

    func delete(_ urls: [URL]) {
        var items: [DeletionUndoHistory.Item] = []
        for url in urls {
            do {
                let trashed = try SealDeleter.delete(url: url, saveFolder: config.saveFolder)
                items.append(.init(trashedURL: trashed, originalURL: url))
            } catch {
                os_log("library delete failed: %{public}@", log: log, type: .error, String(describing: error))
            }
        }
        // One undoable event per gesture. Library deletes never reopen on
        // undo (containedOpenFile false) — cross-tab open-file deletes are a
        // known v1 limitation.
        globalUndo?.record(.fileEvent(.init(items: items, kind: .deletion,
                                            containedOpenFile: false, at: Date())))
        ActivityHighlightStore.shared.mark(items.map(\.trashedURL))
        // Let the editor drop a trashed file from its canvas (an AVPlayer
        // would otherwise keep streaming the moved file indefinitely).
        if !items.isEmpty {
            NotificationCenter.default.post(name: .capturesTrashed, object: items.map(\.originalURL))
        }
        reload()
    }

    func restore(_ urls: [URL]) {
        var items: [DeletionUndoHistory.Item] = []
        for url in urls {
            do {
                // All .seal packages (image and video) restore uniformly to the save folder.
                let back = try SealDeleter.restore(url: url, saveFolder: config.saveFolder)
                items.append(.init(trashedURL: url, originalURL: back))
            }
            catch { os_log("library restore failed: %{public}@", log: log, type: .error, String(describing: error)) }
        }
        // One undoable event per gesture — undo re-deletes the whole batch.
        globalUndo?.record(.fileEvent(.init(items: items, kind: .restoration,
                                            containedOpenFile: false, at: Date())))
        ActivityHighlightStore.shared.mark(items.map(\.originalURL))
        reload()
    }

    func permanentlyDelete(_ urls: [URL]) {
        var purged: [URL] = []
        for url in urls {
            do {
                try SealDeleter.permanentlyDelete(url: url)
                purged.append(url)
            }
            catch { os_log("library purge failed: %{public}@", log: log, type: .error, String(describing: error)) }
        }
        // Let the editor drop a purged file from its canvas/strips.
        if !purged.isEmpty {
            NotificationCenter.default.post(name: .capturesPermanentlyDeleted, object: purged)
        }
        reload()
    }

    /// Apply a Favorite and/or Status change to every given capture, then
    /// reload so the grid/filters/badges reflect it. Locked packages are
    /// skipped (consistent with other batch ops).
    /// Favourites, collections and triage status are LIBRARY membership
    /// metadata: a capture cannot be "a favourite" while sitting outside the
    /// library, and Scratch is purged on a timer, so leaving it there would
    /// quietly delete something the user just marked as worth keeping. Filing
    /// it first is the only coherent reading of the gesture — and it is
    /// announced exactly like a fresh capture so the index and strips pick it
    /// up. Returns the URLs to act on: moved ones for scratch, unchanged
    /// otherwise.
    private func promotingScratch(_ urls: [URL]) -> [URL] {
        guard urls.contains(where: ScratchCapture.isScratch) else { return urls }
        var acted: [URL] = []
        var moved: [URL] = []
        for url in urls {
            guard ScratchCapture.isScratch(url) else { acted.append(url); continue }
            do {
                let dest = try ScratchCapture.keep(url, saveFolder: config.saveFolder)
                acted.append(dest)
                moved.append(dest)
            } catch {
                os_log("scratch keep (implicit) failed %{public}@: %{public}@", log: log,
                       type: .error, url.lastPathComponent, String(describing: error))
            }
        }
        if !moved.isEmpty {
            NotificationCenter.default.post(name: .captureFilesImported, object: moved,
                                            userInfo: ["kind": "capture"])
        }
        return acted
    }

    func setWorkflow(_ urls: [URL], isFavorite: Bool? = nil, status: CaptureStatus? = nil) {
        let urls = promotingScratch(urls)
        for url in urls where url.pathExtension == "seal" {
            // The metadata store resolves the package key and writes the
            // (re-encrypted) manifest. A genuinely locked session (no key)
            // throws and the package is left unchanged. Do NOT pre-skip on
            // `isLocked` — that only means "encrypted at rest", which is every
            // package when encryption is on, and would drop the edit silently.
            do {
                try SealMetadataStore.setWorkflow(isFavorite: isFavorite, status: status, to: url)
                NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
            } catch {
                os_log("setWorkflow write failed %{public}@: %{public}@",
                       log: log, type: .error, url.lastPathComponent, String(describing: error))
            }
        }
        reload()
    }

    /// Favorite toggle for the single selected item, driven from the Info panel
    /// star. Flips `selectedInfo` IN PLACE so the star updates instantly with no
    /// panel reload/flash, writes the manifest, and lets `reload()` refresh the
    /// grid/Favorites tallies (the same-item info refresh no longer flashes).
    func toggleFavorite(_ url: URL) {
        guard url.pathExtension == "seal" else { return }
        let newValue = !(selectedInfo?.isFavorite ?? false)
        selectedInfo?.isFavorite = newValue          // optimistic, in place
        do {
            try SealMetadataStore.setWorkflow(isFavorite: newValue, to: url)
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
        } catch {
            os_log("toggleFavorite write failed %{public}@: %{public}@",
                   log: log, type: .error, url.lastPathComponent, String(describing: error))
            selectedInfo?.isFavorite = !newValue     // revert on failure
        }
        reload()
    }

    // MARK: - Drag out / drop in
    // Grid/list drag-out is AppKit-bridged via `buildDragItems(for:)` +
    // `DraggableTile` (SwiftUI can't drag a multi-selection). See LibraryDragOut.

    /// AppKit dragging items for a multi-file drag-out (SwiftUI can't drag a
    /// selection): one file item per selected exportable capture — an eager temp
    /// file, or an async promise for encrypted video that reports into a shared
    /// progress `session` — plus a hidden identity item so in-app sidebar drops
    /// (collections / Favorites) still resolve the real captures. Dragging a tile
    /// in the multi-selection brings the whole selection; otherwise just it.
    /// Returns nil when nothing in the set can be exported (all locked), and
    /// always nil in Locked Archive — those packages are inert by design,
    /// regardless of whether some unrelated identity happens to be unlocked.
    @MainActor
    func buildDragItems(for item: LibraryItem) -> (items: [NSDraggingItem], retainers: [AnyObject])? {
        guard !section.isLockedArchive else { return nil }
        let dragSet: [URL] = selection.contains(item.url)
            ? items.map(\.url).filter { selection.contains($0) }
            : [item.url]
        let sources: [CaptureDragPayload.Source] = dragSet.compactMap { url in
            guard let li = items.first(where: { $0.url == url }) else { return nil }
            return .init(url: li.url, displayName: li.displayName, isVideo: li.isVideo)
        }
        let exportable = sources.filter { CaptureDragPayload.canExport($0.url) }
        guard !exportable.isEmpty else { return nil }

        // Writer strategy is chosen ONCE, before anything is rendered, because
        // writers must be homogeneous (see `needsPromises`). Multi drags stay
        // promises so every write is post-drop and trackable by the progress
        // sheet — "N of M" — and so nothing is rendered for a drag that may
        // never complete.
        //
        // A SINGLE eagerly-renderable capture takes a plain file URL instead.
        // Promise-only was the Library's behaviour since multi-export landed,
        // and it silently broke every target that cannot resolve a promise:
        // Terminal path insert, canvas insert, anything reading only
        // `public.file-url`. The recent strip already made this exact trade;
        // this brings the two into line.
        let count = exportable.count
        let identityData = CaptureDragPayload.captureListData(for: exportable.map(\.url))
        var usePromises = CaptureDragPayload.needsPromises(
            count: count,
            anyRequiresPromise: exportable.contains { CaptureDragPayload.requiresPromise($0) })
        // At most ONE render reaches here (multi is covered above). A render
        // that unexpectedly fails falls back to a promise rather than dragging
        // nothing.
        let eagerURL = usePromises ? nil : CaptureDragPayload.eagerFileURL(for: exportable[0])
        if !usePromises && eagerURL == nil { usePromises = true }

        if let eagerURL, !usePromises {
            // One item carrying BOTH worlds: the file URL for Terminal and the
            // canvas, the identity so a sidebar collection drop still resolves
            // the real .seal.
            let item = CaptureDragPayload.identityURLItem(fileURL: eagerURL,
                                                          captureListData: identityData)
            let dragItem = NSDraggingItem(pasteboardWriter: item)
            let icon = NSWorkspace.shared.icon(for: CaptureDragPayload.fileType(for: exportable[0]))
            icon.size = NSSize(width: 64, height: 64)
            let iconFrame = NSRect(x: 0, y: 0, width: 64, height: 64)
            let hinted = DragPeekHint.composed(for: icon, in: iconFrame)
            dragItem.setDraggingFrame(hinted.frame, contents: hinted.image)
            return ([dragItem], [])
        }

        let session = DragExportSession(totalItems: count, host: NSApp.keyWindow, immediate: count >= 2)

        // The in-app identity (real .seal URLs) rides on the FIRST item's own
        // pasteboard — NOT a separate item, which Finder rejects (it can make no
        // file from an identity-only item, so it refuses the whole drop). The
        // first item is always a proper NSFilePromiseProvider (the file drag type
        // Finder accepts) carrying the identity too.
        var retainers: [AnyObject] = []
        var draggingItems: [NSDraggingItem] = []
        // ALL items are file promises (homogeneous): the first must be a promise
        // to carry the identity, and a drag mixing promises with plain file-URL
        // items drops the URL items (Finder keeps only the promises). Every item
        // reports into the session so the sheet's "N of M" spans them all.
        for (index, src) in exportable.enumerated() {
            let di = (index == 0)
                ? CaptureDragPayload.identityPromiseItem(for: src, session: session, captureListData: identityData)
                : CaptureDragPayload.promiseItem(for: src, session: session)
            retainers.append(di.retainer)   // weak delegate — hold for the session
            let writer: NSPasteboardWriting = di.provider
            let dragItem = NSDraggingItem(pasteboardWriter: writer)
            let icon = NSWorkspace.shared.icon(for: CaptureDragPayload.fileType(for: src))
            icon.size = NSSize(width: 64, height: 64)
            let iconFrame = NSRect(x: CGFloat(index) * 6, y: CGFloat(index) * -6,
                                   width: 64, height: 64)
            if index == 0 {
                let hinted = DragPeekHint.composed(for: icon, in: iconFrame)
                dragItem.setDraggingFrame(hinted.frame, contents: hinted.image)
            } else {
                dragItem.setDraggingFrame(iconFrame, contents: icon)
            }
            draggingItems.append(dragItem)
        }
        return (draggingItems, retainers)
    }

    /// Files dropped onto the grid from outside the app → import (same path
    /// as ⌘O / Import…). Own drags and library files are filtered out.
    var onImportFiles: (([URL]) -> Void)?

    /// Locked Archive banner's Restore… button → the recovery-code restore
    /// sheet. Set by `EditorWindowController` right after construction (modal
    /// presentation lives at the window-controller layer, like the recovery
    /// and lockout-explainer sheets).
    var onRestoreArchive: (() -> Void)?
    func handleImportDrop(_ urls: [URL]) {
        let importable = CaptureDragPayload.importableDropURLs(
            urls, saveFolder: config.saveFolder)
        guard !importable.isEmpty else { return }
        onImportFiles?(importable)
    }

    /// Add captures to a collection (skips captures already in it).
    func addToCollection(_ urls: [URL], collectionID: UUID) {
        let urls = promotingScratch(urls)
        for url in urls {
            let current = item(for: url)?.collectionIDs ?? []
            guard !current.contains(collectionID) else { continue }
            try? SealMetadataStore.setCollections(current + [collectionID], to: url)
        }
        reload()
    }

    /// Remove captures from a collection (skips captures not in it).
    func removeFromCollection(_ urls: [URL], collectionID: UUID) {
        for url in urls {
            let current = item(for: url)?.collectionIDs ?? []
            guard current.contains(collectionID) else { continue }
            try? SealMetadataStore.setCollections(current.filter { $0 != collectionID }, to: url)
        }
        reload()
    }

    /// Create a new collection by name and immediately add the given captures to it.
    func createCollectionAndAdd(name: String, targets: [URL]) async {
        do {
            let collection = try await ensureCollectionStore().create(name: name, now: Date())
            collectionOperationError = nil
            await reloadCollections()
            addToCollection(targets, collectionID: collection.id)
        } catch {
            reportCollectionOperationError(error)
        }
    }

    /// Add a formatted tag to `url` (no-op on empty/dup); persists + notifies.
    /// Uses `TagNormalizer.format` (formatting only) — the correct entry point
    /// for manual tag entry. Locked packages are skipped (mirrors `setWorkflow`).
    func addTag(_ raw: String, to url: URL) {
        let tag = TagNormalizer.format([raw]).first ?? ""
        guard !tag.isEmpty, url.pathExtension == "seal" else { return }
        do {
            try SealMetadataStore.update(at: url, createIfMissing: true) { meta in
                if !meta.tags.contains(tag) { meta.tags.append(tag) }
            }
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
        } catch {
            os_log("addTag write failed %{public}@: %{public}@",
                   log: log, type: .error, url.lastPathComponent, String(describing: error))
        }
    }

    /// Remove a tag from `url`; persists + notifies. A genuinely locked session
    /// (no key) throws and is skipped — but do NOT pre-skip on `isLocked`.
    func removeTag(_ tag: String, from url: URL) {
        guard url.pathExtension == "seal" else { return }
        do {
            try SealMetadataStore.update(at: url) { meta in
                meta.tags.removeAll { $0 == tag }
            }
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
        } catch {
            os_log("removeTag write failed %{public}@: %{public}@",
                   log: log, type: .error, url.lastPathComponent, String(describing: error))
        }
    }

    /// Rename a capture by setting its manual `userTitle` (blank clears it,
    /// falling back to the filename). Persists via the manifest, notifies, reloads.
    /// A genuinely locked session (no key) throws and is skipped — but do NOT
    /// pre-skip on `isLocked` (true for every encrypted-at-rest package even
    /// with the session unlocked; the addTag/favorite convention).
    func setUserTitle(_ url: URL, to raw: String) {
        guard url.pathExtension == "seal" else { return }
        let title = sanitizedUserTitle(raw)
        do {
            try SealMetadataStore.update(at: url, createIfMissing: true) { meta in meta.userTitle = title }
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
            reload()
        } catch {
            os_log("setUserTitle write failed %{public}@: %{public}@",
                   log: log, type: .error, url.lastPathComponent, String(describing: error))
        }
    }

    /// Duplicate the given captures (whole `.seal`, every persisted edit). Each
    /// copy is named "<name> copy"; the list reloads and selects the new copies.
    func duplicate(_ urls: [URL]) {
        let targets = urls.filter { $0.pathExtension == "seal" }
        guard !targets.isEmpty else { return }
        let new = CaptureDuplicator.duplicate(targets) {
            self.item(for: $0)?.displayName ?? CaptureDisplayName.resolve(for: $0)
        }
        guard !new.isEmpty else { return }
        pendingSelectAfterReload = Set(new)
        reload()
    }

}

/// Persistent outline shown after a delete/restore (or its undo/redo). Stays
/// until the user clicks elsewhere (the view model clears the URL), then fades.
/// Orange to read as distinct from the blue selection accent.
private struct ActivityHighlight: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.orange, lineWidth: 3)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.4), value: active)
    }
}

/// Per-card frames in the grid's coordinate space, collected for marquee
/// hit-testing.
private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(\.colorScheme) private var colorScheme
    /// Keyboard focus on the search field, so clicking a grid/list item can
    /// resign it (a plain TextField otherwise keeps first responder).
    @FocusState private var searchFocused: Bool
    @State private var showDeleteForeverConfirm = false
    @State private var showEmptyTrashConfirm = false

    // Marquee (rubber-band) selection state — grid view only.
    @State private var cardFrames: [URL: CGRect] = [:]
    // Manual single/double-click detection: a single `.onTapGesture` selects
    // immediately (no waiting on a count-2 recognizer), and a second tap on the
    // same item within the double-click interval opens it.
    @State private var lastTapURL: URL?
    @State private var lastTapTime: Date?
    @State private var marqueeBand: CGRect?
    @State private var marqueeBase: Set<URL> = []
    @State private var marqueeActive = false

    // Collections sidebar prompts: one alert for create/rename (rename when
    // `collectionRenameTarget` is set), plus a delete confirmation.
    @State private var showCollectionNamePrompt = false
    @State private var collectionNameDraft = ""
    @State private var collectionRenameTarget: UUID?

    // Capture rename prompt (context-menu "Rename…").
    @State private var showRenamePrompt = false
    @State private var renameDraft = ""
    @State private var renameTarget: URL?
    /// When set, the collection-name prompt will add these captures to the newly
    /// created collection (triggered from the grid "New Collection…" menu item).
    @State private var pendingCollectionAddTargets: [URL]?
    /// Sidebar width captured at the start of a divider drag (nil when not dragging).
    @State private var sidebarDragStartWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: viewModel.sidebarWidth)
            sidebarResizeDivider
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Plain backdrop behind the whole pane (the opaque sidebar covers the
        // left, the opaque header band covers the top).
        .background(Color(nsColor: Theme.backdropColor))
        // Let card names / OCR snippets be selected and copied like a web page.
        .textSelection(.enabled)
        // Bottom floating action toolbar is grid-only; the list view acts on the
        // selected row inline (its per-row quick-actions).
        .overlay(alignment: .bottom) {
            if viewModel.viewMode == .grid { selectionToolbar }
        }
        // Quick Look is a separate floating panel window (so it can be resized
        // larger than the app window). This zero-size bridge attaches it to the
        // host window and shows/hides it with `quickLookOpen`.
        .background {
            QuickLookPanelPresenter(
                viewModel: viewModel,
                isPresented: viewModel.quickLookOpen,
                selectionKey: viewModel.selection.first)
        }
        .confirmationDialog(
            "Delete \(viewModel.selection.count) item\(viewModel.selection.count == 1 ? "" : "s") forever? This cannot be undone.",
            isPresented: $showDeleteForeverConfirm
        ) {
            Button("Delete Forever", role: .destructive) {
                viewModel.permanentlyDelete(Array(viewModel.selection))
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Empty Trash? \(viewModel.sectionItems.count) item\(viewModel.sectionItems.count == 1 ? "" : "s") will be permanently deleted. This cannot be undone.",
            isPresented: $showEmptyTrashConfirm
        ) {
            Button("Empty Trash", role: .destructive) {
                viewModel.permanentlyDelete(viewModel.sectionItems.map(\.url))
            }
            Button("Cancel", role: .cancel) {}
        }
        // Keep the File-menu "Export Encrypted Package…" command in sync with the
        // Library selection (the menu observes ExportMenuState.shared). Only the
        // cheap flags are computed here — this fires per marquee tick, and
        // resolving full sources per change made large selections slow.
        .onChange(of: viewModel.selection, initial: true) {
            let vm = viewModel
            let urls = Array(vm.selection)
            ExportMenuState.shared.update(
                isEmpty: urls.isEmpty,
                hasVideo: urls.contains { vm.item(for: $0)?.isVideo == true },
                owner: .library,
                provider: { [weak vm] in
                    guard let vm else { return [] }
                    return vm.exportSources(for: urls)
                })
        }
        .onDisappear { ExportMenuState.shared.clear(owner: .library) }
    }

    // MARK: sidebar

    /// The sidebar/content divider, made draggable to resize the sidebar. A
    /// hairline divider with a wider transparent grab strip on top; the width is
    /// clamped and persisted (mirrors the editor's right-panel resize).
    private var sidebarResizeDivider: some View {
        Divider()
            .overlay(alignment: .center) {
                ZStack {
                    // Short centered grabber line hints the divider is draggable
                    // (mirrors the editor's SidebarResizeHandle).
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 2, height: 28)
                    // Wider transparent strip = the grab/hit area.
                    Color.clear.frame(width: 12).contentShape(Rectangle())
                }
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                // Measure the drag in GLOBAL space so the moving divider (the
                // sidebar resizes under it) doesn't re-anchor the gesture and
                // cause jitter/shake.
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let start = sidebarDragStartWidth ?? viewModel.sidebarWidth
                            sidebarDragStartWidth = start
                            viewModel.sidebarWidth = LibrarySidebarWidthPreference.clamp(start + value.translation.width)
                        }
                        .onEnded { _ in
                            sidebarDragStartWidth = nil
                            LibrarySidebarWidthPreference.store(viewModel.sidebarWidth)
                        }
                )
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    viewModel.importNew()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .help("Import images or Sealshot packages into your Library")
                .appKitTooltip("Import images or Sealshot packages into your Library")

                // Beside Import rather than buried in a right-click menu on
                // the All Files row, where nobody would find it: this is for
                // people who prefer managing captures in Finder, and a feature
                // they have to discover by right-clicking a sidebar label may
                // as well not exist.
                Button {
                    viewModel.openLibraryFolderInFinder()
                } label: {
                    Label("Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .help("Open the library folder in Finder")
                .appKitTooltip("Open the library folder in Finder")
            }

            // The section list + date tree scroll together when the tree is long.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIBRARY").font(.caption).foregroundStyle(.secondary)

                    sectionRow(.allFiles)
                    sectionRow(.recents)
                    collectionsGroup
                    // Only once a scratch capture exists — the row explains
                    // "where did my capture go" and vanishes when the answer
                    // is "nowhere special".
                    if viewModel.showScratchSection {
                        sectionRow(.scratch)
                    }
                    sectionRow(.trash)
                    // Only shown once the quarantine folder actually holds a
                    // locked package — an empty/never-created folder stays hidden.
                    if viewModel.hasLockedArchive {
                        sectionRow(.lockedArchive)
                    }

                    // `dateTree` renders its own leading Divider + "BY DATE" header
                    // when there are date facets, so it visually separates itself
                    // from Trash above (and shows nothing when there are no captures).
                    dateTree

                    // `tagFacet` renders its own leading Divider + "BY TAG" header
                    // when there are user tags; hidden entirely when none exist.
                    tagFacet

                    // Context-aware info: single-item details, multi-selection
                    // aggregate, or library/results aggregate.
                    LibraryInfoSection(viewModel: viewModel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .task { await viewModel.reloadCollections() }
        // Create / Rename share one alert (a text field bound to `collectionNameDraft`).
        .alert(collectionRenameTarget == nil ? "New Collection" : "Rename Collection",
               isPresented: $showCollectionNamePrompt) {
            TextField("Name", text: $collectionNameDraft)
            Button("Cancel", role: .cancel) {
                collectionRenameTarget = nil
                pendingCollectionAddTargets = nil
            }
            Button(collectionRenameTarget == nil ? "Create" : "Rename") {
                let name = collectionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let target = collectionRenameTarget
                let addTargets = pendingCollectionAddTargets
                collectionRenameTarget = nil
                pendingCollectionAddTargets = nil
                guard !name.isEmpty else { return }
                Task {
                    if let id = target {
                        await viewModel.renameCollection(id: id, to: name)
                    } else if let urls = addTargets {
                        await viewModel.createCollectionAndAdd(name: name, targets: urls)
                    } else {
                        await viewModel.createCollection(name: name)
                    }
                }
            }
        }
        .alert("Rename", isPresented: $showRenamePrompt) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let url = renameTarget { viewModel.setUserTitle(url, to: renameDraft) }
                renameTarget = nil
            }
        } message: { Text("Enter a new name for this capture.") }
        .alert("Collection Error", isPresented: Binding(
            get: { viewModel.collectionOperationError != nil },
            set: { showing in
                if !showing { viewModel.clearCollectionOperationError() }
            })) {
            Button("OK") { viewModel.clearCollectionOperationError() }
        } message: {
            Text(viewModel.collectionOperationError ?? "The collection could not be saved.")
        }
    }

    /// One top-level section row (All Files / Recents / Trash). Extracted from the
    /// old `ForEach(LibrarySection.allCases)` so the section rows and the
    /// Collections group can be interleaved. `.collections` is rendered by the
    /// expandable `collectionsGroup` instead, not by this helper.
    @ViewBuilder
    private func sectionRow(_ s: LibrarySection) -> some View {
        let button = Button {
            viewModel.clearSelection()
            viewModel.section = s
        } label: {
            HStack(spacing: 8) {
                Image(systemName: s.symbol).frame(width: 18)
                Text(s.title)
                Spacer()
                // Scratch carries its weight on the row: what is waiting here
                // is on a 7-day timer, and with recordings in the mix that can
                // be gigabytes. A number nobody had to go looking for.
                if let size = viewModel.sizeLabel(for: s) {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(viewModel.section == s ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // Only All Files gets an export action; other sections (Recents / Trash)
        // have no menu. exportAllFiles resolves members from the full index and
        // no-ops if the library is empty.
        if s == .allFiles {
            button.contextMenu {
                Button("Export All Files…") { exportAllFiles() }
                Divider()
                Button("Open in Finder") { viewModel.openLibraryFolderInFinder() }
            }
        } else {
            button
        }
    }

    /// "Collections": an expandable group. The header row selects the Collections
    /// root (album browser) on the label, toggles the disclosure on the chevron,
    /// and carries the "＋" create button. When expanded it lists ★ Favorites
    /// (pinned, no rename/delete) then one selectable row per manual collection
    /// Export a collection as a `.sealshare` package: resolve its members from
    /// the full index (not the loaded section), then open the export sheet with
    /// the package tagged by the collection descriptor. Shared by the sidebar
    /// row menu and the album-browser tile menu.
    private func exportCollection(_ id: UUID) {
        Task {
            let sources = await viewModel.collectionExportSources(collectionID: id)
            guard !sources.isEmpty,
                  let c = viewModel.collections.first(where: { $0.id == id })
            else { return }
            ExportPackageCoordinator.present(
                sources: sources, host: NSApp.keyWindow,
                collection: ShareCollectionDescriptor(id: c.id, name: c.name))
        }
    }

    /// Export the Favorites facet as a package. Favorites has no collection id,
    /// so members resolve by the favorite flag and the package carries a
    /// synthetic "Favorites" descriptor (import "As Collection" makes a
    /// collection named Favorites).
    private func exportFavorites() {
        Task {
            let sources = await viewModel.favoriteExportSources()
            guard !sources.isEmpty else { return }
            ExportPackageCoordinator.present(
                sources: sources, host: NSApp.keyWindow,
                collection: ShareCollectionDescriptor(id: UUID(), name: "Favorites"))
        }
    }

    /// Export the ENTIRE library as one `.sealshare` package — every capture,
    /// resolved from the full index. Treats "All Files" like a very large
    /// collection: the package carries a synthetic "All Files" descriptor, so an
    /// "As Collection" import lands them in a collection named All Files.
    private func exportAllFiles() {
        Task {
            let sources = await viewModel.allExportSources()
            guard !sources.isEmpty else { return }
            ExportPackageCoordinator.present(
                sources: sources, host: NSApp.keyWindow,
                collection: ShareCollectionDescriptor(id: UUID(), name: "All Files"))
        }
    }

    /// Confirm deleting a collection, offering to also move its media to Trash.
    /// A SwiftUI `.alert` can't host a checkbox, so this uses an NSAlert with a
    /// checkbox accessory (default off). The member count comes from the full
    /// index so it's accurate even for members outside the current view.
    private func requestDeleteCollection(_ id: UUID) {
        Task { @MainActor in
            let memberURLs = await viewModel.allCollectionMemberURLs(id)
            let alert = NSAlert()
            alert.messageText = "Delete Collection?"
            alert.informativeText = memberURLs.isEmpty
                ? "This removes the collection. Captures themselves are not deleted."
                : "This removes the collection. Its captures are not deleted unless you choose to below."
            alert.addButton(withTitle: "Delete")   // default (Return)
            alert.addButton(withTitle: "Cancel")   // Escape
            var checkbox: NSButton?
            if !memberURLs.isEmpty {
                let n = memberURLs.count
                let cb = NSButton(
                    checkboxWithTitle: "Also move \(n) \(n == 1 ? "item" : "items") in this collection to Trash",
                    target: nil, action: nil)
                cb.state = .off
                cb.sizeToFit()
                cb.frame.size.width = max(cb.frame.width, 260)
                alert.accessoryView = cb
                checkbox = cb
            }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let alsoDelete = (checkbox?.state == .on) ? memberURLs : nil
            await viewModel.deleteCollection(id: id, deleteMemberURLs: alsoDelete)
        }
    }

    /// (name + member count, right-click → Export / Rename / Delete).
    @ViewBuilder
    private var collectionsGroup: some View {
        let rootSelected = viewModel.section == .collections && viewModel.collectionSelection == .none
        HStack(spacing: 6) {
            // Chevron toggles expansion only.
            Button {
                viewModel.isCollectionsExpanded.toggle()
            } label: {
                Image(systemName: viewModel.isCollectionsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    // Solid, taller hit target so the small chevron doesn't miss
                    // taps (a bare glyph only registers on its opaque pixels).
                    .frame(width: 12, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Label selects the Collections root (album browser).
            Button {
                viewModel.selectCollectionsRoot()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder").frame(width: 18)
                    Text("Collections").lineLimit(1)
                    Spacer()
                    Text("\(viewModel.sidebarCollections.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(rootSelected ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                collectionRenameTarget = nil
                collectionNameDraft = ""
                pendingCollectionAddTargets = nil
                showCollectionNamePrompt = true
            } label: {
                Image(systemName: "plus").font(.caption2).frame(width: 12)
            }
            .buttonStyle(.plain)
            .help("New collection")
        }

        if viewModel.isCollectionsExpanded {
            ForEach(viewModel.sidebarCollections) { row in
                if row.isFavorites {
                    dateRow(title: "★ \(row.name)", count: row.count, indent: 1,
                            selected: viewModel.collectionSelection == .favorites,
                            chevron: nil) {
                        viewModel.selectFavorites()
                    }
                    // Drop tiles here → mark them favorites. AppKit, not
                    // `.onDrop`: the drag is an AppKit promise drag and SwiftUI
                    // cannot see its in-app identity type (see LibraryDropIn).
                    .libraryDropIn { viewModel.setWorkflow($0, isFavorite: true) }
                    // Favorites can be exported (not renamed/deleted). Resolves
                    // members by the favorite flag from the full index.
                    .contextMenu {
                        Button("Export Favorites…") { exportFavorites() }
                    }
                } else if let id = row.collectionID {
                    dateRow(title: row.name, count: row.count, indent: 1,
                            selected: viewModel.collectionSelection == .collection(id),
                            chevron: nil) {
                        viewModel.selectCollection(id)
                    }
                    // Drop tiles here → add them to this collection.
                    .libraryDropIn { viewModel.addToCollection($0, collectionID: id) }
                    .contextMenu {
                        // Always shown (not gated on the sidebar's section-scoped
                        // count, which can read 0 for a non-empty collection when
                        // another section is loaded). exportCollection resolves
                        // members from the full index and no-ops if truly empty.
                        Button("Export Collection…") { exportCollection(id) }
                        Divider()
                        Button("Rename…") {
                            collectionRenameTarget = id
                            collectionNameDraft = row.name
                            // Present next tick so the draft is committed before
                            // the alert's TextField is built — otherwise SwiftUI
                            // shows it empty instead of prefilled (known bug).
                            DispatchQueue.main.async { showCollectionNamePrompt = true }
                        }
                        Button("Delete…", role: .destructive) {
                            requestDeleteCollection(id)
                        }
                    }
                }
            }
        }
    }

    /// "Browse by date": pinned Today/Last-7-days buckets + a Year→Month→Day
    /// accordion tree. Only active days are listed; days appear when a month is
    /// expanded. Clicking a Year/Month/Day filters the grid immediately.
    @ViewBuilder
    private var dateTree: some View {
        let facets = viewModel.dateFacets
        if !facets.isEmpty {
            Divider().padding(.vertical, 4)
            Text("BY DATE").font(.caption).foregroundStyle(.secondary)

            // Always-present clear: keeps the filter when switching section, but
            // never strands it if the active date isn't in the new section.
            dateRow(title: "All dates", count: viewModel.sectionItems.count, indent: 0,
                    selected: viewModel.dateFilter == .none, chevron: nil) {
                viewModel.selectDate(.none)
            }

            if facets.todayCount > 0 {
                dateRow(title: "Today", count: facets.todayCount, indent: 0,
                        selected: viewModel.dateFilter == .today, chevron: nil) {
                    viewModel.selectDate(.today)
                }
            }
            if facets.last7Count > 0 {
                dateRow(title: "Last 7 days", count: facets.last7Count, indent: 0,
                        selected: viewModel.dateFilter == .last7Days, chevron: nil) {
                    viewModel.selectDate(.last7Days)
                }
            }

            ForEach(facets.years, id: \.year) { year in
                dateRow(title: "\(year.year)", count: year.count, indent: 0,
                        selected: viewModel.dateFilter == .year(year.year),
                        chevron: viewModel.expandedYear == year.year ? "chevron.down" : "chevron.right",
                        onChevron: { viewModel.toggleYear(year.year) }) {
                    viewModel.selectDate(.year(year.year))
                }
                if viewModel.expandedYear == year.year {
                    ForEach(year.months, id: \.month) { month in
                        dateRow(title: libraryMonthName(month.month), count: month.count, indent: 1,
                                selected: viewModel.dateFilter == .month(year: year.year, month: month.month),
                                chevron: viewModel.expandedMonth == month.month ? "chevron.down" : "chevron.right",
                                onChevron: { viewModel.toggleMonth(month.month) }) {
                            viewModel.selectDate(.month(year: year.year, month: month.month))
                        }
                        if viewModel.expandedMonth == month.month {
                            ForEach(month.days, id: \.day) { day in
                                dateRow(title: String(format: "%02d", day.day), count: day.count, indent: 2,
                                        selected: viewModel.dateFilter == .day(year: year.year, month: month.month, day: day.day),
                                        chevron: nil) {
                                    viewModel.selectDate(.day(year: year.year, month: month.month, day: day.day))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// One row of the date tree: optional leading chevron (toggles expansion),
    /// a title, and a trailing count. Highlighted when it's the active filter.
    @ViewBuilder
    private func dateRow(title: String, count: Int, indent: Int, selected: Bool,
                         chevron: String?, onChevron: (() -> Void)? = nil,
                         onSelect: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if let chevron {
                Button { (onChevron ?? onSelect)() } label: {
                    Image(systemName: chevron).font(.caption2)
                        // Solid, taller hit target — a bare glyph only registers
                        // on its opaque pixels, causing missed expand/collapse taps.
                        .frame(width: 12, height: 22)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Text(title).font(.callout)
                    Spacer()
                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(selected ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(indent) * 12)
    }

    /// "BY TAG": a collapsible accordion group listing each user tag with a
    /// checkbox + count. Hidden when no user tags exist. The expanded list is
    /// height-capped (~8 rows) with an internal scroll so it never pushes the
    /// info section down. Styling mirrors the "BY DATE" header and `dateRow`.
    @ViewBuilder private var tagFacet: some View {
        if !viewModel.libraryTags.isEmpty {
            Divider().padding(.vertical, 4)

            // Header: whole row toggles the group; "Clear" is a Button so its
            // tap is consumed and doesn't also toggle. (Chevron is a plain image.)
            HStack(spacing: 6) {
                Image(systemName: viewModel.isTagsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .frame(width: 12, height: 22)
                    .foregroundStyle(.secondary)

                Text("BY TAG").font(.caption).foregroundStyle(.secondary)
                Spacer()

                if !viewModel.selectedTags.isEmpty {
                    Button("Clear") { viewModel.clearTagFilter() }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.isTagsExpanded.toggle() }

            if viewModel.isTagsExpanded {
                // Height-capped internal scroll (~8 rows × ~28pt each ≈ 228pt).
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(viewModel.libraryTags, id: \.tag) { entry in
                            tagRow(entry.tag, count: entry.count,
                                   on: viewModel.selectedTags.contains(entry.tag))
                        }
                    }
                }
                .frame(maxHeight: 228)
            }
        }
    }

    /// One row in the tag facet: checkbox icon (left column matches dateRow's
    /// chevron column width), tag name, and trailing count. Tapping anywhere
    /// calls `toggleTag`. Highlighted when the tag is in `selectedTags`.
    @ViewBuilder private func tagRow(_ tag: String, count: Int, on: Bool) -> some View {
        Button {
            viewModel.toggleTag(tag)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .frame(width: 20, height: 22)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                HStack(spacing: 6) {
                    Text(tag).font(.callout).lineLimit(1)
                    Spacer()
                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(on ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: content

    /// Sort control: a menu of the four fields; the active one shows a
    /// direction chevron, and re-selecting it flips the direction.
    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortField.allCases, id: \.self) { field in
                Button {
                    viewModel.chooseSort(field)
                } label: {
                    if viewModel.sort.field == field {
                        Label(field.displayName,
                              systemImage: viewModel.sort.direction == .ascending ? "chevron.up" : "chevron.down")
                    } else {
                        Text(field.displayName)
                    }
                }
            }
        } label: {
            Label("Sort: \(viewModel.sort.field.displayName)",
                  systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort the library")
    }

    /// File type filter (All / Images / Videos) — segmented icons matching
    /// the editor strip's media filter.
    private var fileTypeFilterMenu: some View {
        Picker("", selection: $viewModel.fileTypeFilter) {
            Image(systemName: "square.grid.2x2").tag(LibraryFileTypeFilter.all)
                .help("All files")
            Image(systemName: "photo").tag(LibraryFileTypeFilter.images)
                .help("Images")
            Image(systemName: "video").tag(LibraryFileTypeFilter.videos)
                .help("Videos")
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("Filter by file type")
    }

    /// A row of removable chips — one per active grid-narrowing filter — with a
    /// trailing "Clear All". Shown only when a filter is active (and not at the
    /// Collections album browser, where those filters don't apply).
    @ViewBuilder private var activeFilterBar: some View {
        if viewModel.hasActiveFilter {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Text("Filters").font(.caption).foregroundStyle(.secondary)
                    if let sectionLabel = viewModel.sectionChipLabel {
                        filterChip(sectionLabel) { viewModel.section = .allFiles }
                    }
                    if viewModel.fileTypeFilter != .all {
                        filterChip(viewModel.fileTypeFilter.title) { viewModel.fileTypeFilter = .all }
                    }
                    if viewModel.dateFilter != .none {
                        filterChip(viewModel.dateFilter.chipLabel) { viewModel.dateFilter = .none }
                    }
                    ForEach(viewModel.selectedTags.sorted(), id: \.self) { tag in
                        filterChip(tag) { viewModel.toggleTag(tag) }
                    }
                    if !viewModel.searchText.isEmpty {
                        filterChip("“\(viewModel.searchText)”") { viewModel.searchText = "" }
                    }
                    Spacer(minLength: 8)
                    Button("Clear All") { viewModel.clearAllFilters() }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: Theme.surfaceColor))
                Divider()
            }
        }
    }

    /// One removable filter chip: label + an ✕ that clears just that filter.
    /// Accent text reads well on light, but is muddy on dark over the accent
    /// tint — so use the high-contrast label color there (and a stronger tint).
    private func filterChip(_ text: String, clear: @escaping () -> Void) -> some View {
        let dark = colorScheme == .dark
        return HStack(spacing: 5) {
            Text(text).font(.caption).lineLimit(1)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Remove this filter")
        }
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 4)
        .foregroundStyle(dark ? Color.primary : Color.accentColor)
        .background(Color.accentColor.opacity(dark ? 0.30 : 0.13), in: Capsule())
    }

    /// Continuous tile-size control (grid mode only), flanked by dense/sparse
    /// grid glyphs. Snapped to `LibraryTileSize.step` so the grid reflows a
    /// handful of times per drag rather than per pixel.
    private var tileSizeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $viewModel.tileWidth,
                   in: LibraryTileSize.min...LibraryTileSize.max,
                   step: LibraryTileSize.step)
                .controlSize(.small)
                .frame(width: 100)
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
        }
        .help("Adjust thumbnail size")
    }

    private var content: some View {
        // Header band reads as elevated chrome (surface), the beehive backdrop is
        // confined to the scrollable body below — matching the editor, where the
        // header sits on surface and only the canvas carries the hex texture.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        // The file-type filter rides INLINE with the title
                        // text — the subtitle below can be wider than the
                        // title, and a filter placed after the whole block
                        // would drift with it instead of hugging the title
                        // ("All Files", "Recents", "Trash", …).
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(viewModel.contentTitle).font(.title2.bold())
                                .lineLimit(1).truncationMode(.tail)
                            if !viewModel.isAlbumBrowser { fileTypeFilterMenu }
                        }
                        Text(viewModel.subtitle).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    // Keep the title/subtitle readable on narrow windows: give it
                    // layout priority so the flexible search field shrinks first.
                    .layoutPriority(1)
                    // Search sits centered between the leading (title+filter)
                    // and trailing (view controls) groups.
                    Spacer(minLength: 12)
                    if !viewModel.isAlbumBrowser { librarySearchField }
                    Spacer(minLength: 12)
                    if viewModel.viewMode == .grid { tileSizeSlider }
                    sortMenu
                    Picker("", selection: $viewModel.viewMode) {
                        Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                        Image(systemName: "list.bullet").tag(LibraryViewMode.list)
                    }
                    .pickerStyle(.segmented).frame(width: 90).labelsHidden()
                }
                // Empty Trash: its own right-aligned row below the controls. Shown
                // ONLY for the Trash section; always present there but disabled
                // when empty. Permanently deletes ALL items in Trash.
                if viewModel.section.isTrash {
                    HStack {
                        Spacer()
                        Button("Empty") { showEmptyTrashConfirm = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(viewModel.sectionItems.isEmpty)
                            .help("Permanently delete all items in Trash")
                    }
                }
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: Theme.surfaceColor))

            Divider()

            if viewModel.section.isLockedArchive {
                lockedArchiveBanner
            }

            activeFilterBar

            Group {
                // Collections root (no specific collection selected) shows the
                // album browser — tiles must appear even with zero captures, so
                // this branch wins over the empty-state below.
                if viewModel.section == .collections && viewModel.collectionSelection == .none {
                    LibraryCollectionBrowser(
                        viewModel: viewModel,
                        onNew: {
                            collectionRenameTarget = nil
                            collectionNameDraft = ""
                            pendingCollectionAddTargets = nil
                            showCollectionNamePrompt = true
                        },
                        onRename: { row in
                            guard let id = row.collectionID else { return }
                            collectionRenameTarget = id
                            collectionNameDraft = row.name
                            // Present next tick so the draft is committed before
                            // the alert's TextField is built (see sidebar rename).
                            DispatchQueue.main.async { showCollectionNamePrompt = true }
                        },
                        onDelete: { id in
                            requestDeleteCollection(id)
                        },
                        onExport: { id in exportCollection(id) },
                        onExportFavorites: { exportFavorites() })
                } else if viewModel.items.isEmpty {
                    emptyState
                } else if viewModel.viewMode == .grid {
                    gridBody
                } else {
                    listBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Explains why Locked Archive items can't be opened, with the
    /// recovery-code restore action. The button routes to the shared
    /// `LockedArchiveRestoreView` sheet hosted by `EditorWindowController`
    /// (wired via `viewModel.onRestoreArchive`).
    ///
    /// `Locked-Unrecoverable/` can hold two different kinds of content: items
    /// a guided lockout reset archived (restorable — a keystore seed came
    /// with them) and items quarantined when Enhanced security was turned
    /// off (`EncryptionProvisioner.disable` deletes keystore.json without
    /// archiving a seed — those can never come back through Restore…). When
    /// no keystore seed exists at all, the Restore… button would only ever
    /// fail, so it's hidden and the copy drops the restorability promise.
    private var lockedArchiveBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.doc.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(viewModel.archiveHasKeystore
                ? "These items are encrypted with a key this Mac no longer has. Restore with your recovery code."
                : "These items are encrypted with a key this Mac no longer has.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if viewModel.archiveHasKeystore {
                Button("Restore…") {
                    viewModel.onRestoreArchive?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .overlay(Divider(), alignment: .bottom)
    }

    /// Search field styled to read unmistakably as search, with placeholder
    /// copy advertising that the index covers OCR text, not just names.
    private var librarySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search titles, tags & text in images", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { viewModel.submitSearch() }
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: Theme.surfaceBorderColor), lineWidth: 1)
        )
        // Flexible so a narrow window shrinks the search box instead of
        // squeezing the title/subtitle (which has layout priority).
        .frame(minWidth: 140, maxWidth: 300)
        .help("Matches words found inside your screenshots")
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(viewModel.searchText.isEmpty
                 ? "No captures here yet."
                 : "No matches — search looks at titles, tags, and text inside images.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Coordinate space the grid's card frames, marquee gesture, and band
    /// overlay all share, so the rubber-band math lines up.
    private static let gridSpace = "libraryGridSpace"

    private var gridBody: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: viewModel.tileWidth), spacing: LibraryViewModel.gridSpacing)], spacing: LibraryViewModel.gridSpacing) {
                    ForEach(viewModel.items) { item in
                        LibraryCardView(item: item, isSelected: viewModel.selection.contains(item.url),
                                        showsCheckmark: viewModel.selection.contains(item.url) && viewModel.selection.count > 1,
                                        thumbnailHeight: LibraryTileSize.height(forWidth: viewModel.tileWidth),
                                        isLockedArchive: viewModel.section.isLockedArchive,
                                        onNameClick: { handleClick(item.url) },
                                        onNameDoubleClick: { viewModel.activate(item) })
                            .modifier(ActivityHighlight(
                                active: viewModel.highlightedKeys.contains(item.url.activityHighlightKey),
                                cornerRadius: 10))
                            // Report each card's frame for marquee hit-testing.
                            .background(GeometryReader { geo in
                                Color.clear.preference(
                                    key: CardFramesKey.self,
                                    value: [item.url: geo.frame(in: .named(Self.gridSpace))])
                            })
                            .onTapGesture { handleTap(item) }
                            .contextMenu { itemMenu(for: item.url) }
                            // Drag out: one rendered file per selected capture
                            // (mixed image/video) → Finder, plus the in-app
                            // identity type for sidebar drops. AppKit-bridged
                            // because SwiftUI can't drag a multi-selection; taps/
                            // menus stay in SwiftUI (see LibraryDragOut).
                            .libraryDragOut(build: { viewModel.buildDragItems(for: item) })
                    }
                }
                // Measure the grid's own width (pre-padding) to track how many
                // columns are on screen, so ↑/↓ jump the right number of items.
                .background(GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size.width, initial: true) { _, w in
                            viewModel.gridColumns = LibraryViewModel.gridColumnCount(
                                forWidth: w, tileWidth: viewModel.tileWidth)
                        }
                        // Resizing tiles reflows columns without a width change,
                        // so ↑/↓ row jumps must be recomputed here too.
                        .onChange(of: viewModel.tileWidth) { _, _ in
                            viewModel.gridColumns = LibraryViewModel.gridColumnCount(
                                forWidth: geo.size.width, tileWidth: viewModel.tileWidth)
                        }
                })
                // Pad FIRST so the marquee hit layer + shared coordinate space
                // below cover the 20pt margin too — otherwise a drag started in
                // the grid's edge/corner margin (e.g. above-left of the first
                // tile) hit nothing and no band appeared.
                .padding(20)
                // Stretch the grid to at least the viewport height so the hit
                // layer below reaches past the last row — otherwise a marquee
                // can't start in the empty space beneath the final tiles. Still
                // a minimum, so overflowing content scrolls as usual.
                .frame(minHeight: viewport.size.height, alignment: .top)
                // ⌘+scroll over the grid resizes tiles (gated to the grid, so it
                // won't fight the editor canvas's own ⌘+scroll zoom).
                .libraryTileZoom { deltaY, precise in
                    viewModel.nudgeTileWidth(scrollDeltaY: deltaY, precise: precise)
                }
                // Marquee hit layer sits behind the cards: a drag from empty
                // space (including the padded margin and the area below the last
                // row) rubber-bands; a drag on a card hits the card (which only
                // taps), so it starts on empty space only. macOS ScrollViews
                // don't pan on mouse-drag, so this doesn't fight scrolling.
                .background(marqueeHitLayer)
                .overlay(marqueeBandOverlay)
                .coordinateSpace(.named(Self.gridSpace))
                .onPreferenceChange(CardFramesKey.self) { cardFrames = $0 }
            }
            .onChange(of: viewModel.scrollTarget, initial: true) { scrollToTarget(proxy) }
            // Files dropped from Finder (etc.) import into the Library —
            // internal tile drags are filtered out by the identity type.
            .onDrop(of: [.fileURL], isTargeted: nil) { handleFileImportDrop($0) }
            }
        }
    }

    /// Transparent layer hosting the marquee drag. A `minimumDistance` keeps a
    /// click from starting a band; selection updates live as the band grows.
    private var marqueeHitLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            // A plain click on empty space clears the selection and the
            // delete/restore highlight.
            .onTapGesture {
                viewModel.clearSelection()
                viewModel.dismissHighlight(clicked: nil)
            }
            .gesture(
                DragGesture(minimumDistance: MarqueeSelection.minDragDistance,
                            coordinateSpace: .named(Self.gridSpace))
                    .onChanged { value in
                        if !marqueeActive {
                            marqueeActive = true
                            viewModel.dismissHighlight(clicked: nil)
                            let additive = NSEvent.modifierFlags.contains(.command)
                                || NSEvent.modifierFlags.contains(.shift)
                            marqueeBase = additive ? viewModel.selection : []
                        }
                        let rect = MarqueeSelection.rect(from: value.startLocation, to: value.location)
                        marqueeBand = rect
                        let touched = MarqueeSelection.touched(rect: rect, frames: cardFrames)
                        viewModel.selection = MarqueeSelection.combine(touched: touched, base: marqueeBase)
                    }
                    .onEnded { _ in
                        // Only anchor a shift-extend if a band actually formed;
                        // a sub-threshold press falls through to the tap handler.
                        if marqueeActive { viewModel.finishMarquee() }
                        marqueeActive = false
                        marqueeBand = nil
                        marqueeBase = []
                    }
            )
    }

    @ViewBuilder private var marqueeBandOverlay: some View {
        if let band = marqueeBand {
            Rectangle()
                .fill(Color.accentColor.opacity(0.18))
                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: band.width, height: band.height)
                .position(x: band.midX, y: band.midY)
                .allowsHitTesting(false)
        }
    }

    /// Resolve the in-app capture-list payload from a sidebar drop and run
    /// `action` with the capture URLs on the main queue.
    /// Files dropped from OUTSIDE the app (Finder etc.) onto the grid/list →
    /// import, exactly like ⌘O. Internal tile drags carry the capture-list
    /// identity type and are ignored here.
    private func handleFileImportDrop(_ providers: [NSItemProvider]) -> Bool {
        let external = providers.filter {
            !$0.hasItemConformingToTypeIdentifier(CaptureDragPayload.captureListTypeIdentifier)
                && $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !external.isEmpty else { return false }
        let group = DispatchGroup()
        let collected = CollectedURLs()
        for provider in external {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collected.append(url)
                } else if let url = item as? URL {
                    collected.append(url)
                }
            }
        }
        let vm = viewModel
        group.notify(queue: .main) { vm.handleImportDrop(collected.urls) }
        return true
    }

    /// Thread-safe URL accumulator for the drop's concurrent load callbacks.
    private final class CollectedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Per-item row used by both the flat list and the date-grouped list, so
    /// the closure bodies are not duplicated between the two paths.
    @ViewBuilder
    private func listRow(_ item: LibraryItem) -> some View {
        LibraryRowView(
            item: item,
            isSelected: viewModel.selection.contains(item.url),
            isTrash: viewModel.section.isTrash,
            isLockedArchive: viewModel.section.isLockedArchive,
            onFinder: { viewModel.showInFinder([item.url]) },
            onExport: { ExportImageCoordinator.present(sources: viewModel.exportSources(for: [item.url]), host: NSApp.keyWindow) },
            // Trash rows purge (via the Delete Forever confirmation, like the
            // grid toolbar / context menu) — a plain delete() would move the
            // file into Deleted/ where it already lives and just rename it
            // in place (" 2", " 3", …), never actually removing it.
            onDelete: viewModel.section.isTrash
                ? { viewModel.selectOnly(item.url); showDeleteForeverConfirm = true }
                : { viewModel.delete([item.url]) },
            onRestore: { viewModel.restore([item.url]) },
            onToggleFavorite: { viewModel.setWorkflow([item.url], isFavorite: !item.isFavorite) },
            onNameClick: { handleClick(item.url) },
            onNameDoubleClick: { viewModel.activate(item) })
            .modifier(ActivityHighlight(
                active: viewModel.highlightedKeys.contains(item.url.activityHighlightKey),
                cornerRadius: 6))
            .onTapGesture { handleTap(item) }
            .contextMenu { itemMenu(for: item.url) }
            // Multi-file drag-out (see the grid) — a selection drags all rows as
            // individual files; taps/menus stay in SwiftUI.
            .libraryDragOut(build: { viewModel.buildDragItems(for: item) })
    }

    private var listBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section(header: listHeader) {
                        // Date sort: bucket items into Today / Last 7 days / Earlier.
                        // The group labels are plain rows (not Section headers) so
                        // only the column header above is pinned — avoiding two
                        // levels of stuck headers when scrolling.
                        if viewModel.sort.field == .date && viewModel.sort.direction == .descending {
                            ForEach(groupedByDate(viewModel.items, now: Date()), id: \.label) { group in
                                Text(group.label.uppercased())
                                    .font(.system(size: 12, weight: .semibold))
                                    .kerning(0.6)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 10)
                                ForEach(group.items) { item in listRow(item); Divider() }
                            }
                        } else {
                            ForEach(viewModel.items) { item in listRow(item); Divider() }
                        }
                    }
                }
                // Solid gray table behind the whole list (matching the sticky
                // column header) instead of the hex backdrop showing through —
                // softer than the white surface. Grid view keeps the
                // transparent look.
                .background(Color(nsColor: Theme.listTableColor))
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .onChange(of: viewModel.scrollTarget, initial: true) { scrollToTarget(proxy) }
            .onDrop(of: [.fileURL], isTargeted: nil) { handleFileImportDrop($0) }
        }
    }

    /// Sticky, clickable column header. Sortable cells call `chooseSort`
    /// (sets the field on first click, flips direction on re-click) and show a
    /// ▲/▼ on the active field. Non-sortable spacers keep row/header aligned.
    private var listHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: LibraryListColumns.rowSpacing) {
                Spacer().frame(width: LibraryListColumns.kindIcon)
                Spacer().frame(width: LibraryListColumns.thumb)
                headerCell("Name", field: .name).frame(maxWidth: .infinity, alignment: .leading)
                headerCell("App", field: .sourceApp).frame(width: LibraryListColumns.app, alignment: .trailing)
                headerCell("Dimensions", field: .dimensions).frame(width: LibraryListColumns.dimensions, alignment: .trailing)
                headerCell("Size", field: .size).frame(width: LibraryListColumns.size, alignment: .trailing)
                headerCell("Date", field: .date).frame(width: LibraryListColumns.date, alignment: .trailing)
                Spacer().frame(width: LibraryListColumns.star)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.vertical, 6).padding(.horizontal, 8)
            // Divider under the column header so it reads as table chrome,
            // separated from the first data row.
            Divider()
        }
        .background(Color(nsColor: Theme.listTableColor))
    }

    @ViewBuilder
    private func headerCell(_ title: String, field: LibrarySortField) -> some View {
        let active = viewModel.sort.field == field
        Button { viewModel.chooseSort(field) } label: {
            HStack(spacing: 2) {
                Text(title.uppercased())
                if active {
                    Image(systemName: viewModel.sort.direction == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    /// Scroll to an explicitly requested item (reveal or keyboard nav), then
    /// clear the request. Plain mouse selection never sets `scrollTarget`, so
    /// clicking a tile no longer yanks the grid around.
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = viewModel.scrollTarget else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(target, anchor: .center)
        }
        viewModel.scrollTarget = nil
    }

    private func handleClick(_ url: URL) {
        searchFocused = false   // clicking an item resigns the search field
        viewModel.dismissHighlight(clicked: url)
        if NSEvent.modifierFlags.contains(.shift) {
            viewModel.selectRange(to: url)
        } else if NSEvent.modifierFlags.contains(.command) {
            viewModel.toggle(url)
        } else {
            viewModel.selectOnly(url)
        }
    }

    /// Single tap selects immediately; a second tap on the same item within the
    /// system double-click interval opens it. Replaces a count-1 + count-2
    /// gesture pair, which made SwiftUI delay selection to disambiguate.
    private func handleTap(_ item: LibraryItem) {
        searchFocused = false   // any grid tap (select or open) resigns search
        // A modifier-tap (⇧ range / ⌘ toggle) is a selection gesture, never an
        // open — don't let a repeat land on the double-tap-to-open path.
        let modified = NSEvent.modifierFlags.contains(.shift)
            || NSEvent.modifierFlags.contains(.command)
        let now = Date()
        if !modified, lastTapURL == item.url, let last = lastTapTime,
           now.timeIntervalSince(last) <= NSEvent.doubleClickInterval {
            lastTapURL = nil
            lastTapTime = nil
            viewModel.activate(item)
            return
        }
        lastTapURL = modified ? nil : item.url
        lastTapTime = modified ? nil : now
        handleClick(item.url)
    }

    // MARK: actions menu (shared by context menu + floating toolbar)

    /// The URLs an action applies to: the whole selection if the target is in
    /// it, otherwise just the target.
    private func actionTargets(_ url: URL) -> [URL] {
        viewModel.selection.contains(url) ? Array(viewModel.selection) : [url]
    }

    /// Highlight the right-clicked item (Finder-style) unless it's already in
    /// the selection. SwiftUI evaluates the context-menu builder during layout,
    /// not only on right-click, so without the event guard a re-render would
    /// re-select neighbor cards in a feedback loop. Gating on the live
    /// rightMouseDown event ensures this only fires for an actual right-click;
    /// the async defer keeps the mutation out of the view-update pass.
    private func highlightForContextMenu(_ url: URL) {
        guard NSApp.currentEvent?.type == .rightMouseDown else { return }
        guard !viewModel.selection.contains(url) else { return }
        DispatchQueue.main.async { viewModel.selectOnly(url) }
    }

    @ViewBuilder
    private func itemMenu(for url: URL) -> some View {
        let _ = highlightForContextMenu(url)
        // Locked Archive is visible-but-inert: decrypting isn't possible, so
        // the menu reduces to the one action that still works.
        if viewModel.section.isLockedArchive {
            Button("Show in Finder") { viewModel.showInFinder(actionTargets(url)) }
        } else if viewModel.section.isScratch {
            // Everything the Library offers, plus the keep gesture. A scratch
            // capture is a normal capture that simply hasn't been filed, so
            // preview/export/duplicate/rename all apply unchanged; the actions
            // that mean MEMBERSHIP (favourite, collection) file it first —
            // see `promotingScratch`.
            Button("Add to Library") { viewModel.addToLibrary(actionTargets(url)) }
            Divider()
            itemMenuBody(for: url)
        } else {
            itemMenuBody(for: url)
        }
    }

    @ViewBuilder
    private func itemMenuBody(for url: URL) -> some View {
        if let item = viewModel.item(for: url), item.isVideo {
            // "Open" (not "Play"): it opens the video in the editor, not inline.
            Button("Open") { viewModel.play(item) }
        } else {
            Button("Open") { viewModel.open(url) }
        }
        Button("Preview") { viewModel.previewInQuickLook(url) }
        Button("Show in Finder") { viewModel.showInFinder(actionTargets(url)) }
        let targetURLs = viewModel.selection.contains(url) ? Array(viewModel.selection) : [url]
        Button(targetURLs.count > 1 ? "Export \(targetURLs.count) Images" : "Export to Image") {
            ExportImageCoordinator.present(sources: viewModel.exportSources(for: targetURLs),
                                           host: NSApp.keyWindow)
        }
        let videoTargets = targetURLs.filter { viewModel.item(for: $0)?.isVideo == true }
        if !videoTargets.isEmpty {
            Button(videoTargets.count > 1 ? "Export \(videoTargets.count) Videos…" : "Export to Video…") {
                VideoExportCoordinator.present(sources: viewModel.exportSources(for: targetURLs),
                                               host: NSApp.keyWindow)
            }
        }
        Button(targetURLs.count > 1
               ? "Export \(targetURLs.count) Items as Package…"
               : "Export to Package…") {
            ExportPackageCoordinator.present(sources: viewModel.exportSources(for: targetURLs),
                                             host: NSApp.keyWindow)
        }
        if !viewModel.section.isTrash {
            Divider()
            Button(targetURLs.count > 1 ? "Duplicate \(targetURLs.count) Items" : "Duplicate") {
                viewModel.duplicate(targetURLs)
            }
            let targets = actionTargets(url)
            let allFavorite = targets.allSatisfy { viewModel.item(for: $0)?.isFavorite == true }
            Button(allFavorite ? "Remove from Favorites" : "Add to Favorites") {
                viewModel.setWorkflow(targets, isFavorite: !allFavorite)
            }
            Menu("Add to Collection") {
                Button("★ Favorites") { viewModel.setWorkflow(targets, isFavorite: true) }
                Divider()
                ForEach(viewModel.collections) { c in
                    Button(c.name) {
                        viewModel.addToCollection(targets, collectionID: c.id)
                    }
                }
                if !viewModel.collections.isEmpty { Divider() }
                Button("New Collection…") {
                    pendingCollectionAddTargets = targets
                    collectionRenameTarget = nil
                    collectionNameDraft = ""
                    showCollectionNamePrompt = true
                }
            }
            if case .collection(let activeID) = viewModel.collectionSelection {
                Button("Remove from this Collection") {
                    viewModel.removeFromCollection(targets, collectionID: activeID)
                }
            } else if viewModel.collectionSelection == .favorites {
                Button("Remove from this Collection") {
                    viewModel.setWorkflow(targets, isFavorite: false)
                }
            }
            if !viewModel.section.isTrash, let item = viewModel.item(for: url) {
                Button("Rename…") {
                    renameTarget = url
                    renameDraft = item.displayName
                    showRenamePrompt = true
                }
            }
        }
        Divider()
        if viewModel.section.isTrash {
            Button("Restore") { viewModel.restore(actionTargets(url)) }
            Button("Delete Forever", role: .destructive) {
                // Preserve a multi-selection: only collapse to this row when it
                // isn't already part of the selection (mirrors `actionTargets`,
                // like Restore/Show in Finder/Export above). Previously this
                // always called selectOnly(url), so "select all → Delete
                // Forever" deleted only the right-clicked row.
                if !viewModel.selection.contains(url) { viewModel.selectOnly(url) }
                showDeleteForeverConfirm = true
            }
        } else {
            Button("Delete", role: .destructive) { viewModel.delete(actionTargets(url)) }
        }
    }

    @ViewBuilder
    private var selectionToolbar: some View {
        if !viewModel.selection.isEmpty {
            let urls = Array(viewModel.selection)
            HStack(spacing: 14) {
                Text("\(urls.count) selected").font(.callout.weight(.medium))
                if viewModel.section.isLockedArchive {
                    // Locked Archive is visible-but-inert: only Finder reveal works.
                    Button { viewModel.showInFinder(urls) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                } else {
                    if urls.count == 1, let item = viewModel.item(for: urls[0]) {
                        Button { viewModel.activate(item) } label: {
                            Image(systemName: item.isVideo ? "play.fill" : "pencil")
                        }
                        .help("Open")   // opens in the editor (video or image), not inline playback
                    }
                    Button { viewModel.showInFinder(urls) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                    Button {
                        ExportPackageCoordinator.present(sources: viewModel.exportSources(for: Array(viewModel.selection)),
                                                         host: NSApp.keyWindow)
                    } label: {
                        Image(systemName: "lock.doc")
                    }
                    .help("Export to Package…")
                    if viewModel.section.isTrash {
                        Button { viewModel.restore(urls) } label: { Image(systemName: "arrow.uturn.backward") }
                            .help("Restore")
                        Button { showDeleteForeverConfirm = true } label: { Image(systemName: "trash") }
                            .help("Delete Forever")
                    } else {
                        Button { viewModel.delete(urls) } label: { Image(systemName: "trash") }
                            .help("Delete")
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
            .padding(.bottom, 18)
        }
    }
}

// MARK: - Card / Row

private struct LibraryCardView: View {
    let item: LibraryItem
    let isSelected: Bool
    /// The corner checkmark is a multi-selection affordance — only shown when
    /// more than one item is selected (a lone selection reads from the tint/ring).
    let showsCheckmark: Bool
    /// Thumbnail height, derived from the user's tile-size choice.
    let thumbnailHeight: CGFloat
    /// True in the Locked Archive section: the whole tile dims and shows a
    /// lock badge — a visual cue that this package can't be opened.
    var isLockedArchive: Bool = false
    /// Clicking the name selects / opens the tile (mirrors the list-view name).
    let onNameClick: () -> Void
    let onNameDoubleClick: () -> Void
    @State private var thumb: NSImage?
    @State private var videoThumb: CGImage?
    @State private var durationText: String?
    /// The name doesn't fit at the tile width and is showing an ellipsis.
    /// Height of the name+snippet+date block, so the reveal panel can cover it.

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                if showsCheckmark {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            // Name + snippet + date. Grouped so the reveal panel (below) can
            // opaquely cover the WHOLE block — otherwise a wrapped name overlaps
            // the timestamp.
            VStack(alignment: .leading, spacing: 6) {
                // Name: a non-selectable AppKit label (a SwiftUI Text would be
                // caught by the pane's `.textSelection(.enabled)`, so a click
                // starts selection and reveals the clipped full text). Hover
                // shows the full name as a native tooltip; truncation drives the
                // reveal.
                SelectableRowLabel(
                    text: item.displayName,
                    tooltip: item.displayName,
                    onClick: onNameClick,
                    onDoubleClick: onNameDoubleClick,
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Why the search matched: excerpt of the OCR text containing the hit.
                if let snippet = item.matchSnippet {
                    Text(searchSnippetDisplay(snippet))
                        .font(.caption2).italic().foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text(item.modified, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Selecting a tile deliberately does NOT reveal the full name in a
            // panel any more: it changed the card's appearance on click, and
            // covered the date to do it. The name is a hover tooltip, which
            // costs nothing and is available whether or not the tile is
            // selected.
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        // Locked Archive: dim the whole tile — open/edit/QuickLook/drag are
        // all disabled for it (see `LibraryViewModel.activate`); selection
        // still works (selection isn't gated).
        .opacity(isLockedArchive ? 0.55 : 1.0)
        // Keyed on mtime too: an editor save re-fires the task and refetches
        // the changed thumbnail (unchanged files re-appear as NSCache hits —
        // ThumbnailStore keys by the same mtime). Video thumbs stay once-per-
        // url: canvas edits don't apply to them and frame extraction is dear.
        // The generation re-fires it on unlock, for cards that drew while the
        // session was locked and could not decrypt.
        .task(id: ThumbnailGeneration.shared.taskID(item.thumbnailKey)) {
            if item.isVideo {
                if videoThumb == nil { videoThumb = await VideoThumbnail.load(for: item.url) }
                // Use the authoritative duration from the index when available;
                // fall back to async VideoDurationLoader for legacy .sealrec/.mov items
                // that have no durationSeconds in the index.
                if durationText == nil {
                    if let s = item.durationSeconds {
                        durationText = VideoPlaybackMath.timeLabel(s)
                    } else if let s = await VideoDurationLoader.seconds(for: item.url) {
                        durationText = VideoPlaybackMath.timeLabel(s)
                    }
                }
            } else if let fresh = await ThumbnailStore.shared.thumbnail(for: item.url) {
                thumb = fresh
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if item.isVideo {
                videoThumbnailImage
            } else if let thumb {
                // Aspect-fit (like the editor canvas) so the whole capture is
                // visible in correct proportions, letterboxed on the backdrop
                // — rather than center-cropped to fill.
                Image(nsImage: thumb).resizable().scaledToFit()
                    .padding(6)
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: thumbnailHeight)
        .frame(maxWidth: .infinity)
        // White "paper" card with a hairline border + soft shadow (Snagit-
        // style) instead of a heavy gray letterbox fill, so aspect-fit shots
        // read as framed thumbnails rather than gray blocks.
        .background(Color(nsColor: Theme.surfaceColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: Theme.surfaceBorderColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
        // Play affordance over video thumbnails.
        .overlay {
            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32)).foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
        // Duration badge, bottom-trailing.
        .overlay(alignment: .bottomTrailing) {
            if item.isVideo, let durationText {
                Text(durationText)
                    .font(.caption2).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        // Format badge for a recording saved WITHOUT the package wrapper —
        // "can I use this file as it is, or does it need exporting?". Top-
        // TRAILING, matching the strip tile so the badge sits in the same place
        // wherever a capture is shown. It yields to the multi-select checkmark,
        // which occupies this corner while selecting; that mode is transient
        // and the badge returns when it ends. A `.seal` shows nothing; absence
        // is the signal.
        .overlay(alignment: .topTrailing) {
            if !showsCheckmark, let format = item.plainMovieFormatLabel {
                Text(format)
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        // Favorite star badge, top-leading (avoids collision with the multi-select checkmark at top-trailing).
        .overlay(alignment: .topLeading) {
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .shadow(radius: 2)
                    .padding(6)
            }
        }
        // Lock badge, bottom-leading — the Locked Archive tell (distinct
        // corner from the favorite star, duration badge, and checkmark).
        .overlay(alignment: .bottomLeading) {
            if isLockedArchive {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.6), in: Circle())
                    .padding(6)
            }
        }
    }

    @ViewBuilder
    private var videoThumbnailImage: some View {
        if let videoThumb {
            Image(decorative: videoThumb, scale: 1).resizable().scaledToFit().padding(6)
        } else {
            Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LibraryRowView: View {
    let item: LibraryItem
    let isSelected: Bool
    let isTrash: Bool
    /// True in the Locked Archive section: dims the row, badges the
    /// thumbnail, and reduces the quick-actions to Show in Finder only.
    var isLockedArchive: Bool = false
    let onFinder: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void
    let onToggleFavorite: () -> Void
    let onNameClick: () -> Void
    let onNameDoubleClick: () -> Void
    @State private var thumb: NSImage?
    @State private var videoThumb: CGImage?
    @State private var hovering = false
    /// Reported by the name label: the display name doesn't fit and is
    /// showing an ellipsis at the current column width.
    @State private var nameTruncated = false

    var body: some View {
        HStack(spacing: LibraryListColumns.rowSpacing) {
            // Kind icon — or, for a recording saved as a plain movie, its
            // container. A 42pt list thumbnail is too small for a legible
            // corner pill, and this column already answers "what kind of thing
            // is this?", so the format goes here instead.
            Group {
                if let format = item.plainMovieFormatLabel {
                    Text(format).font(.system(size: 9, weight: .semibold))
                } else {
                    Image(systemName: item.isVideo ? "play.rectangle" : "photo").font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: LibraryListColumns.kindIcon)

            // Thumbnail
            thumbnailView
                .frame(width: LibraryListColumns.thumb, height: 42)
                .background(Color(nsColor: Theme.surfaceColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: Theme.surfaceBorderColor), lineWidth: 1))
                .overlay {
                    if item.isVideo {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.white.opacity(0.9)).shadow(radius: 2)
                    }
                }
                // Lock badge — same Locked Archive tell as the grid card.
                .overlay(alignment: .bottomLeading) {
                    if isLockedArchive {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.black.opacity(0.6), in: Circle())
                            .padding(2)
                    }
                }

            // Name column. AppKit-backed label: SwiftUI `.help()` tooltips
            // don't fire inside these gesture-laden rows, so a truncated name
            // reveals its full text via a native NSView tooltip instead. The
            // label swallows its own clicks, so it forwards select/open back
            // to the row. The quick-actions sit at the column's trailing edge;
            // the label compresses (truncates) first, so the buttons always
            // fit without shifting the fixed columns.
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // While the row is selected, a truncated name switches to
                    // a wrapping Text showing the whole name — a click
                    // dismisses the system tooltip (AppKit behavior, no way
                    // around it), so selection is what reveals the full name.
                    if isSelected && nameTruncated {
                        Text(item.displayName)
                            .textSelection(.disabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        SelectableRowLabel(
                            text: item.displayName,
                            tooltip: item.displayName,
                            onClick: onNameClick,
                            onDoubleClick: onNameDoubleClick,
                            onTruncationChange: { nameTruncated = $0 })
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let snippet = item.matchSnippet {
                        Text(searchSnippetDisplay(snippet))
                            .font(.caption).italic().foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Quick-actions — only on the selected (highlighted) row, not
                // on a plain hover.
                if isSelected {
                    HStack(spacing: 6) {
                        quickButton("folder", "Show in Finder", onFinder)
                        // Locked Archive: nothing else works — Export/Delete/Restore
                        // all assume a readable manifest.
                        if !isLockedArchive {
                            if isTrash {
                                quickButton("arrow.uturn.backward", "Restore", onRestore)
                                quickButton("trash", "Delete Forever", onDelete)
                            } else {
                                quickButton("square.and.arrow.up", "Export to Image", onExport)
                                quickButton("trash", "Delete", onDelete)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing columns
            Text(item.sourceApp ?? "").lineLimit(1).truncationMode(.tail)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: LibraryListColumns.app, alignment: .trailing)
            Text(LibraryListFormatting.dimensions(item.width, item.height) ?? "")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: LibraryListColumns.dimensions, alignment: .trailing)
            Text(LibraryListFormatting.size(item.fileSize))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: LibraryListColumns.size, alignment: .trailing)
            Text(item.modified, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: LibraryListColumns.date, alignment: .trailing)

            // Favorite star toggle. `.borderless` (not `.plain`) so the button
            // reliably captures its own click inside the row's `.onTapGesture`
            // — a `.plain` button loses the tap to the row selection gesture.
            // Locked-archive rows get a blank column instead: toggling would
            // attempt a manifest rewrite the locked package can't satisfy.
            if isLockedArchive {
                Color.clear.frame(width: LibraryListColumns.star)
            } else {
                Button(action: onToggleFavorite) {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: LibraryListColumns.star)
                .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        // Selection tint wins; otherwise a subtle hover highlight on the row
        // under the cursor; else clear (the list's gray surface shows through).
        .background(isSelected ? Color.accentColor.opacity(0.12)
                    : hovering ? Color.primary.opacity(0.06)
                    : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Locked Archive: dim the whole row (selection tint/hover still show
        // through underneath) — mirrors the grid card's treatment.
        .opacity(isLockedArchive ? 0.55 : 1.0)
        // Keyed on mtime too — an editor save refetches the changed thumbnail
        // (see the grid tile's task for the caching rationale) — and on the
        // thumbnail generation, so a card drawn while the app was locked
        // retries once the session can decrypt.
        .task(id: ThumbnailGeneration.shared.taskID(item.thumbnailKey)) { await loadThumbnail() }
    }

    @ViewBuilder
    private func quickButton(_ systemName: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(.borderless).help(help)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if item.isVideo {
            if let videoThumb {
                Image(decorative: videoThumb, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let thumb {
            Image(nsImage: thumb).resizable().scaledToFit()
        } else {
            Image(systemName: "photo").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadThumbnail() async {
        if item.isVideo {
            if videoThumb == nil { videoThumb = await VideoThumbnail.load(for: item.url) }
        } else if let fresh = await ThumbnailStore.shared.thumbnail(for: item.url) {
            thumb = fresh
        }
    }
}
