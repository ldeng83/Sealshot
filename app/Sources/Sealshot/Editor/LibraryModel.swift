import Foundation

/// The Recents window: captures modified within this many days back.
let libraryRecentsWindowDays = 7

/// Which group of files the Library is showing.
/// Media discrimination (images vs videos) has moved to the File Type filter (Task 2).
enum LibrarySection: String, CaseIterable, Identifiable {
    case allFiles = "All Files"
    case recents = "Recents"
    case collections = "Collections"
    /// Captures taken while "Add captures to Library" is off. A waiting room,
    /// not part of the library proper: visible here so "where did my capture
    /// go" always has an answer, but excluded from All Files/Recents/search
    /// scopes, and purged after `ScratchCapture.retentionDays`.
    case scratch = "Scratch"
    case trash = "Trash"
    /// Visible-but-inert: `.seal` packages this Mac can no longer decrypt,
    /// quarantined under `Quarantine.folderName` (see `LockoutReset` /
    /// the encryption-off quarantine path). Listed for awareness only —
    /// open/edit/QuickLook/drag are disabled; the only actions are "Show in
    /// Finder" and the recovery-code "Restore…" flow.
    case lockedArchive = "Locked Archive"

    var id: String { rawValue }
    var title: String { rawValue }
    var symbol: String {
        switch self {
        case .allFiles: return "square.grid.2x2"
        case .recents: return "clock"
        case .collections: return "folder"
        case .scratch: return "tray"
        case .trash: return "trash"
        case .lockedArchive: return "archivebox"
        }
    }
    /// Trash shows restore + delete-forever instead of delete.
    var isTrash: Bool { self == .trash }
    /// Scratch swaps "Show in Library"-flavoured actions for "Add to Library".
    var isScratch: Bool { self == .scratch }
    /// Locked Archive is read-only/inert — see the case doc above.
    var isLockedArchive: Bool { self == .lockedArchive }
    /// Tolerant decode for the removed Images/Videos cases (and any junk).
    static func from(rawValue: String) -> LibrarySection { LibrarySection(rawValue: rawValue) ?? .allFiles }
}

/// One capture shown in the Library. Identified by its file URL.
struct LibraryItem: Identifiable, Equatable {
    let url: URL
    /// Capture date (when the shot was taken) — see `captureDate`. Used for
    /// the "Sorted by Date" ordering and the date shown on each item.
    let modified: Date
    /// Resolved display name (generated title when available, else filename).
    /// Computed once at item construction to avoid repeated disk reads in SwiftUI body.
    let displayName: String
    /// `.seal` package size on disk, in bytes (0 when unknown). Sort key.
    let fileSize: Int64
    /// Capture category (nil when none — sparse while auto-tagging is off). Sort key.
    let category: ScreenshotCategory?
    /// Whether the capture is marked as a favorite.
    let isFavorite: Bool
    /// Triage status (new / reviewed / archived). Drives the workflow filter.
    let status: CaptureStatus
    /// When the search hit came from the OCR text alone (not filename/title/
    /// tags): a one-line excerpt around the hit, shown on the card so the
    /// user can see why the image matched. Nil otherwise.
    let matchSnippet: String?
    /// True for a video `.seal` package (captureKind == .screenRecording or
    /// .importedVideo) rather than an image capture. Drives the card's thumbnail
    /// source and the open-vs-play action.
    let isVideo: Bool
    /// Duration in seconds for video items (nil for images). Populated from the
    /// index (CaptureIndexRow.durationSeconds) so the card doesn't need an async
    /// VideoDurationLoader call for video `.seal` packages.
    let durationSeconds: Double?
    /// The collection UUIDs this capture belongs to. Populated from the index
    /// (CaptureIndexRow.collectionIDs) so the collection filter can work in-memory.
    let collectionIDs: [UUID]
    /// Source pixel dimensions (0 = unknown). Sort/display key.
    let width: Int
    let height: Int
    /// Capturing app name; nil when unknown. Sort/display key.
    let sourceApp: String?
    /// Present only when both dimensions are known (non-zero).
    var dimensions: (w: Int, h: Int)? {
        (width > 0 && height > 0) ? (width, height) : nil
    }
    /// User-assigned tags for this capture. Populated from the index
    /// (CaptureIndexRow.tags) so the BY TAG facet can work in-memory.
    let tags: [String]
    /// File mtime from the index (its reconcile freshness key) — NOT the
    /// capture date above. An editor save bumps it, which (a) makes the
    /// rebuilt item non-Equal so the card re-renders, and (b) re-keys the
    /// card's thumbnail task so a stale thumbnail is refetched.
    let fileMtime: Date
    var filename: String { url.lastPathComponent }
    var id: URL { url }
    /// Task identity for the card's thumbnail load: same file + same mtime →
    /// no refetch; a save changes the key and triggers one.
    var thumbnailKey: String { "\(url.path)#\(fileMtime.timeIntervalSince1970)" }
    /// "MOV"/"MP4" for a recording saved WITHOUT the package wrapper, nil for a
    /// `.seal`. It answers the question that setting exists for: can this file
    /// be used as it is, or does it need exporting first? Labelling packages
    /// "SEAL" would put jargon on the common case, so absence is the signal.
    var plainMovieFormatLabel: String? {
        let ext = url.pathExtension.lowercased()
        guard plainMovieExtensions.contains(ext) else { return nil }
        return ext.uppercased()
    }

    init(url: URL, modified: Date, displayName: String, fileSize: Int64 = 0,
         category: ScreenshotCategory? = nil, isFavorite: Bool = false,
         status: CaptureStatus = .new, matchSnippet: String? = nil,
         isVideo: Bool = false, durationSeconds: Double? = nil,
         collectionIDs: [UUID] = [],
         width: Int = 0, height: Int = 0, sourceApp: String? = nil,
         tags: [String] = [], fileMtime: Date = .distantPast) {
        self.url = url
        self.fileMtime = fileMtime
        self.modified = modified
        self.displayName = displayName
        self.fileSize = fileSize
        self.category = category
        self.isFavorite = isFavorite
        self.status = status
        self.matchSnippet = matchSnippet
        self.isVideo = isVideo
        self.durationSeconds = durationSeconds
        self.collectionIDs = collectionIDs
        self.width = width
        self.height = height
        self.sourceApp = sourceApp
        self.tags = tags
    }
}

/// Folder the captures of a section read from. allFiles/recents/collections →
/// saveFolder; trash → `<saveFolder>/Deleted/`; lockedArchive →
/// `<saveFolder>/Locked-Unrecoverable/` (`Quarantine.folderName`).
func libraryFolder(for section: LibrarySection, saveFolder: URL) -> URL {
    switch section {
    case .allFiles, .recents, .collections:
        return saveFolder
    case .scratch:
        return ScratchCapture.folder(under: saveFolder)
    case .trash:
        return saveFolder.appendingPathComponent(SealDeleter.deletedSubfolderName, isDirectory: true)
    case .lockedArchive:
        return saveFolder.appendingPathComponent(Quarantine.folderName, isDirectory: true)
    }
}

/// Whether the sidebar's Locked Archive row should appear: the quarantine
/// folder exists and holds at least one `.seal` package. A cheap stat-level
/// directory listing — no manifest reads, safe to call on every Library
/// reload (see `LibraryViewModel.reload`).
/// Whether the sidebar's Scratch row should appear.
///
/// Two reasons to show it: there ARE unkept captures to see, or the toggle is
/// off — in which case the row is the standing answer to "where do my captures
/// go now", visible before the first one even lands. (The Locked Archive row
/// gates purely on contents; Scratch can't, because an empty Scratch is
/// meaningful the moment the mode is on.)
func scratchRowVisible(hasItems: Bool, capturesAddToLibrary: Bool) -> Bool {
    hasItems || !capturesAddToLibrary
}

/// Whether the Scratch folder actually holds a capture.
enum ScratchPresence {
    static func hasItems(saveFolder: URL, fileManager: FileManager = .default) -> Bool {
        let folder = ScratchCapture.folder(under: saveFolder)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return contents.contains { $0.pathExtension.lowercased() == "seal" }
    }
}

enum LockedArchivePresence {
    static func hasItems(saveFolder: URL, fileManager: FileManager = .default) -> Bool {
        let folder = saveFolder.appendingPathComponent(Quarantine.folderName, isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return contents.contains { $0.pathExtension.lowercased() == "seal" }
    }
}

/// Matching options shared by the Library search and the snippet helper.
private let librarySearchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

/// Pure transform over indexed rows: derive video-ness from captureKind, filter
/// by section window (e.g. the Recents cutoff) and search query, then sort. Media
/// (image/video) filtering is NOT done here — it's an in-memory LibraryFileTypeFilter
/// applied by the view model. A query direct-matches the
/// filename, user title, generated title, or any tag (substring, case/diacritic-
/// insensitive); `ocrHits` carries FTS results for OCR-text hits
/// (path → excerpt) computed by `LibraryIndexDB.ocrMatches`. Direct hits win;
/// OCR-only hits show their excerpt on the card.
func makeLibraryItems(
    rows: [CaptureIndexRow],
    section: LibrarySection,
    search: String,
    now: Date,
    ocrHits: [String: String] = [:],
    sort: LibrarySort = .default
) -> [LibraryItem] {
    let cutoff = now.addingTimeInterval(-Double(libraryRecentsWindowDays) * 86_400)
    let query = search.trimmingCharacters(in: .whitespaces)
    func hits(_ s: String) -> Bool { s.range(of: query, options: librarySearchOptions) != nil }

    let items = rows
        .filter { section != .recents || $0.captureDate >= cutoff }
        .compactMap { row -> (CaptureIndexRow, String?)? in
            guard !query.isEmpty else { return (row, nil) }
            let filename = (row.path as NSString).lastPathComponent
            let direct = hits(filename) || hits(row.title)
                || (row.userTitle.map(hits) ?? false)
                || row.tags.contains(where: hits)
                || row.smartKeywords.contains(where: hits)
            if direct { return (row, nil) }
            if let snippet = ocrHits[row.path] { return (row, snippet) }
            return nil
        }
        .compactMap { row, snippet -> LibraryItem? in
            // .seal packages are directories; building the URL with
            // isDirectory:true makes it equal to the directory URLs that
            // contentsOfDirectory hands the strip ("Show in Library" relies
            // on URL equality for selection).
            let url = URL(fileURLWithPath: row.path,
                          isDirectory: false)
            let isVideo = row.captureKind == .screenRecording
                || row.captureKind == .importedVideo
            let item = LibraryItem(url: url, modified: row.captureDate,
                                   displayName: libraryDisplayName(for: row),
                                   fileSize: row.fileSize, category: row.category,
                                   isFavorite: row.isFavorite, status: row.status,
                                   matchSnippet: snippet, isVideo: isVideo,
                                   // 0 means UNKNOWN, not "zero seconds": a plain
                                   // .mov/.mp4 has no manifest to index a duration
                                   // from. Passing 0 through renders a confident
                                   // "0:00" and suppresses the async
                                   // VideoDurationLoader fallback that exists for
                                   // exactly these files.
                                   durationSeconds: isVideo && row.durationSeconds > 0
                                       ? row.durationSeconds : nil,
                                   collectionIDs: row.collectionIDs,
                                   width: row.width, height: row.height,
                                   sourceApp: row.sourceApp,
                                   tags: row.tags, fileMtime: row.mtime)
            // Media type filtering has moved to the File Type filter (Task 2).
            // All sections show both images and videos.
            return item
        }
    return sortLibraryItems(items, by: sort)
}

/// Rows whose membership contains `collectionID`. Pure; index-independent so
/// it is unit-testable without a live store.
func collectionMemberRows(_ rows: [CaptureIndexRow], collectionID: UUID) -> [CaptureIndexRow] {
    rows.filter { $0.collectionIDs.contains(collectionID) }
}

/// Rows the user has favorited — the "Favorites" facet's members. Pure;
/// index-independent so it is unit-testable without a live store.
func favoriteMemberRows(_ rows: [CaptureIndexRow]) -> [CaptureIndexRow] {
    rows.filter(\.isFavorite)
}

/// One-line display form of a raw FTS snippet: whitespace collapsed (OCR
/// snippets span lines), hit markers stripped, every hit bolded, and the
/// text re-windowed so the first hit lands within the first `leadIn`
/// characters. FTS5 places the hit anywhere in its token window — often past
/// what a single truncated line can show — so without the re-window the
/// "why did this match" line can fail to contain the match.
func searchSnippetDisplay(_ raw: String, leadIn: Int = 18) -> AttributedString {
    let start = Character(LibraryIndexDB.snippetHitStart)
    let end = Character(LibraryIndexDB.snippetHitEnd)
    var text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if let m = text.firstIndex(of: start),
       text.distance(from: text.startIndex, to: m) > leadIn {
        text = "…" + String(text[text.index(m, offsetBy: -leadIn)...])
    }
    var out = AttributedString()
    var current = ""
    var inHit = false
    func flush() {
        guard !current.isEmpty else { return }
        var part = AttributedString(current)
        if inHit { part.inlinePresentationIntent = .stronglyEmphasized }
        out += part
        current = ""
    }
    for ch in text {
        if ch == start { flush(); inHit = true }
        else if ch == end { flush(); inHit = false }
        else { current.append(ch) }
    }
    flush()
    return out
}

/// userTitle override when present, else filename without extension.
func libraryDisplayName(for row: CaptureIndexRow) -> String {
    if let user = row.userTitle,
       !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return user }
    return URL(fileURLWithPath: row.path).deletingPathExtension().lastPathComponent
}
