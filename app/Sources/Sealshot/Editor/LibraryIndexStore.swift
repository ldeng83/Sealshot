import Foundation
import CryptoKit
import os.log

private let indexLog = OSLog(subsystem: "com.seal-shot.sealshot", category: "library-index")

/// Whether a reconcile must re-read a `.seal` manifest solely to backfill the
/// dimensions/source-app columns added after the row was first indexed. A real
/// capture is never 0×0, so once `width > 0` the row never re-reads again;
/// non-`.seal` rows (legacy PNGs) never match, so they don't thrash.
func needsDimensionBackfill(isSeal: Bool, width: Int) -> Bool {
    isSeal && width == 0
}

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "library-store")

extension Notification.Name {
    /// Posted when a reconcile actually changed the index (rows added, removed,
    /// or re-read). `object` is the reconciled folder URL.
    ///
    /// Views that render an index listing must refresh on this. Without it a
    /// background reconcile that fills a previously-empty index leaves every
    /// strip showing the stale empty listing until some unrelated event — or an
    /// app restart — happens to refresh it. Only posted when something changed,
    /// so an idle reconcile doesn't re-refresh every strip for nothing.
    static let libraryIndexDidChange = Notification.Name("com.seal-shot.libraryIndexDidChange")
}

/// Minimal render-ready row for the Recent/Deleted strips: no search, no
/// snippets — just what a tile needs. Built from indexed rows, so listing
/// costs zero manifest reads for unchanged files.
struct StripItem: Equatable {
    let url: URL
    let captureDate: Date
    let displayName: String
    /// True for screen recordings (`.mov`/`.mp4`/`.sealrec`) merged in from the
    /// recordings folder — drives the video thumbnail + play affordance, and
    /// makes a click play rather than open the editor.
    var isVideo: Bool = false
    /// True for `.sealrec` (encrypted at rest): its thumbnail needs the unlocked
    /// recordings key, so it shows a locked placeholder until the session unlocks.
    var isEncrypted: Bool = false
    /// Video duration in seconds, sourced from the index (CaptureIndexRow) like
    /// the Library card. Nil for images and for recordings whose duration the
    /// tile resolves lazily; non-nil lets the tile draw the badge immediately —
    /// crucial for `.seal` videos, which AVURLAsset can't read.
    var durationSeconds: Double? = nil

    /// Merge indexed captures with recordings into one strip list: recordings
    /// become video `StripItem`s, future-dated rows (clock skew) are dropped, the
    /// recent-day window is computed over the UNION (so a recording on a day with
    /// no captures still shows), then sorted newest-first. Pure → unit-tested.
    static func merged(captures: [StripItem], recordings: [RecordingItem],
                       coveringDays: Int, now: Date) -> [StripItem] {
        var candidates = captures.filter { $0.captureDate <= now }
        candidates += recordings.compactMap { rec in
            guard rec.modified <= now else { return nil }
            return StripItem(url: rec.url, captureDate: rec.modified,
                             displayName: rec.name, isVideo: true, isEncrypted: rec.isEncrypted)
        }
        let days = recentCaptureDayWindow(candidates.map(\.captureDate), dayCount: coveringDays)
        let windowed = candidates.filter {
            days.contains(Calendar.current.startOfDay(for: $0.captureDate))
        }
        return windowed.sorted { a, b in
            if a.captureDate != b.captureDate { return a.captureDate > b.captureDate }
            return a.url.path < b.url.path
        }
    }
}

/// How a scanned capture's date should be sourced during reconcile.
enum SealReconcileAction: Equatable {
    /// Manifest read OK → upsert with its stable `createdISO8601`.
    case indexFromManifest
    /// `.seal` whose manifest is momentarily unreadable but already indexed →
    /// keep the existing (stable) date; only refresh mtime.
    case keepExistingDate
    /// `.seal` with no row yet and an unreadable manifest → index a PROVISIONAL
    /// row (so it still lists) with a stat date and the `fileSize == 0`
    /// "re-read me" sentinel, so the next reconcile that CAN read the manifest
    /// replaces the provisional date with the stable one.
    case provisionalUntilReadable
    /// Genuine legacy `.png` (no manifest) → stat-level creation date.
    case legacyStatDate
}

/// Decide how to date a scanned file. A `.seal`'s date lives in its manifest
/// (`createdISO8601`), which is stable across re-saves; its mtime/creationDate
/// are NOT (re-saving resets them), so they must never become a `.seal`'s sort
/// date — doing so floats every re-opened capture to the front of the strip.
func reconcileDateAction(manifestReadable: Bool, isSeal: Bool, hasExistingRow: Bool) -> SealReconcileAction {
    if manifestReadable { return .indexFromManifest }
    if isSeal { return hasExistingRow ? .keepExistingDate : .provisionalUntilReadable }
    return .legacyStatDate
}

/// Owns the SQLite capture index and keeps it reconciled with the save
/// folder. All Library disk I/O happens on this actor; the main actor only
/// receives ready-to-render `[LibraryItem]` snapshots.
actor LibraryIndexStore {

    static let shared = LibraryIndexStore()

    /// Delete the plaintext index when encryption is switched on, rather than
    /// waiting for the first sealed write to remove it.
    ///
    /// `EncryptedIndexFile.persist` already deletes it, but only after a
    /// successful seal — so a crash or force-quit before the first persist
    /// left a plaintext file holding OCR text, titles and tags from before
    /// encryption was enabled. `database()` refuses to open it now, but the
    /// file itself is the exposure: it sits unencrypted in Application Support
    /// where anything can read it. Removing it eagerly closes that window.
    ///
    /// Safe to lose: the index is a disposable cache rebuilt by `reconcile`.
    static func purgePlaintextIndex(at url: URL = LibraryIndexStore.defaultDatabaseURL) {
        try? FileManager.default.removeItem(at: url)
    }

    static var defaultDatabaseURL: URL {
        AppSupportDirectory.file("libraryIndex.sqlite")
    }

    private let databaseURL: URL
    private let legacyIndex: LibrarySearchIndex
    /// nil = not opened yet; .some(nil) = open failed twice (Library lists
    /// empty rather than crashing — the next launch retries).
    private var dbBox: LibraryIndexDB??
    private let keyProvider: @MainActor () -> SymmetricKey?
    /// Whether encryption is switched on, independent of whether the session
    /// is unlocked. `keyProvider` returning nil is ambiguous — it means "no
    /// encryption" for one user and "locked" for another, and those two must
    /// not take the same branch when opening the database. See `database()`.
    private let encryptionEnabled: @MainActor () -> Bool
    private let identityProvider: @MainActor () -> IdentityKey?
    private let pendingQueue: PendingIndexQueue
    /// Cache-identity for the key the current dbBox was opened with — an
    /// HMAC thumbprint, not the key bytes (avoid retaining key material).
    private var activeKeyThumb: Data?
    /// Folders whose one-time capture-date repair has been attempted this
    /// launch (don't re-scan manifests on every reconcile of the same folder).
    private var repairAttemptedFolders: Set<String> = []
    /// Folders that have had their one forced full re-reconcile for the
    /// smart-keywords migration. The DB's `needsSmartKeywordsRemigration`
    /// flag gates the reconcile fast path and is never cleared, so without
    /// this it forced a re-read of every manifest on EVERY pass for the whole
    /// session — ~19,000 reads across one afternoon instead of 320. Its own
    /// comment says "a forced full re-reconcile this launch": once per folder
    /// is what that means.
    private var remigratedFolders: Set<String> = []

    init(databaseURL: URL = LibraryIndexStore.defaultDatabaseURL,
         legacyIndex: LibrarySearchIndex = .shared,
         keyProvider: @escaping @MainActor () -> SymmetricKey? = {
             try? EncryptionSession.shared.contentKey(for: .libraryIndex)
         },
         encryptionEnabled: @escaping @MainActor () -> Bool = {
             EncryptionSession.shared.isEnabled
         },
         identityProvider: @escaping @MainActor () -> IdentityKey? = {
             EncryptionSession.shared.unlockedIdentityForDrain()
         },
         pendingQueue: PendingIndexQueue = PendingIndexQueue(folder: PendingIndexQueue.defaultFolder)) {
        self.databaseURL = databaseURL
        self.legacyIndex = legacyIndex
        self.keyProvider = keyProvider
        self.encryptionEnabled = encryptionEnabled
        self.identityProvider = identityProvider
        self.pendingQueue = pendingQueue
    }

    /// Render-ready items for a section/search: reconcile the section's
    /// folder, then assemble from indexed rows + FTS OCR hits. Unchanged
    /// files cost zero I/O beyond one stat scan.
    /// Total bytes of the captures a section holds, summed from the INDEX
    /// rather than walked on disk — the rows already carry each package's size
    /// (`captureFileSize`, which totals a `.seal` bundle's entries), so this is
    /// a query, not a filesystem crawl over a library that may hold thousands
    /// of captures.
    ///
    /// Rows with `fileSize == 0` are the index's "not yet measured" sentinel
    /// (an unreadable manifest, or a capture seen but not yet re-read); they
    /// simply contribute nothing, so the total reads slightly low rather than
    /// blocking on a re-read. Scratch is deliberately NOT served here: its
    /// captures are unindexed by design, so it keeps its own disk walk.
    /// `reconcileFirst` indexes the folder before summing. Required for a
    /// section the user has not opened this session — the index only learns a
    /// folder's contents when something reconciles it, so Trash's size read as
    /// nothing until it was visited. The caller skips it for the section it is
    /// already loading, whose `items(section:)` call has just reconciled the
    /// same folder; reconciling twice per reload would double the directory
    /// scan on every library refresh.
    func totalBytes(section: LibrarySection, saveFolder: URL,
                    reconcileFirst: Bool = false) async -> Int64 {
        let folder = libraryFolder(for: section, saveFolder: saveFolder)
        if reconcileFirst { await reconcile(folder: folder) }
        guard let (db, _) = await database() else { return 0 }
        let rows = (try? db.rows(inFolder: folder.standardizedFileURL.path)) ?? []
        return rows.reduce(0) { $0 + $1.fileSize }
    }

    func items(section: LibrarySection, saveFolder: URL,
               search: String, now: Date,
               sort: LibrarySort = .default,
               expandedTerms: [String]? = nil) async -> [LibraryItem] {
        let folder = libraryFolder(for: section, saveFolder: saveFolder)
        await reconcile(folder: folder)
        guard let (db, key) = await database() else {
            os_log("items(%{public}@): database unavailable", log: indexLog, type: .default,
                   section.rawValue)
            return []
        }
        await drainPendingIfPossible(into: db, key: key)
        let folderKey = folder.standardizedFileURL.path
        let rows = (try? db.rows(inFolder: folderKey)) ?? []
        os_log("items(%{public}@): folder=%{public}@ rows=%d favs=%d", log: indexLog, type: .default,
               section.rawValue, folderKey, rows.count, rows.filter(\.isFavorite).count)
        let query = search.trimmingCharacters(in: .whitespaces)
        // AI search: OR the expanded keywords (plus the original words) into the
        // OCR FTS query so related text matches too. Direct title/tag matching
        // still uses the literal query. Falls back to the literal FTS otherwise.
        let ocrHits: [String: String]
        if let expandedTerms, !expandedTerms.isEmpty,
           let orQuery = SearchQueryExpander.ftsOrQuery(
                terms: query.split(whereSeparator: \.isWhitespace).map(String.init) + expandedTerms) {
            ocrHits = (try? db.ocrMatches(ftsMatch: orQuery, inFolder: folderKey)) ?? [:]
        } else {
            ocrHits = query.isEmpty ? [:]
                : ((try? db.ocrMatches(query: query, inFolder: folderKey)) ?? [:])
        }
        return makeLibraryItems(rows: rows, section: section, search: query,
                                now: now, ocrHits: ocrHits, sort: sort)
    }

    /// Every capture belonging to `collectionID`, across the whole captures
    /// folder (NOT limited to a loaded section). `.allFiles` maps to the unified
    /// saveFolder, whose index holds both image and video `.seal` rows.
    func collectionMembers(collectionID: UUID, saveFolder: URL) async -> [LibraryItem] {
        let folder = libraryFolder(for: .allFiles, saveFolder: saveFolder)
        await reconcile(folder: folder)
        guard let (db, key) = await database() else { return [] }
        await drainPendingIfPossible(into: db, key: key)
        let folderKey = folder.standardizedFileURL.path
        let rows = (try? db.rows(inFolder: folderKey)) ?? []
        let members = collectionMemberRows(rows, collectionID: collectionID)
        return makeLibraryItems(rows: members, section: .allFiles, search: "", now: Date())
    }

    /// Every favorited capture across the whole captures folder (not limited to
    /// a loaded section) — the "Favorites" facet's members, for export.
    func favoriteMembers(saveFolder: URL) async -> [LibraryItem] {
        let folder = libraryFolder(for: .allFiles, saveFolder: saveFolder)
        await reconcile(folder: folder)
        guard let (db, key) = await database() else { return [] }
        await drainPendingIfPossible(into: db, key: key)
        let folderKey = folder.standardizedFileURL.path
        let rows = (try? db.rows(inFolder: folderKey)) ?? []
        let members = favoriteMemberRows(rows)
        return makeLibraryItems(rows: members, section: .allFiles, search: "", now: Date())
    }

    /// Every capture in the library across the whole captures folder (not limited
    /// to a loaded section) — the "All Files" facet's members, for exporting the
    /// entire library as one package. Same fetch as `favoriteMembers` with no
    /// member filter.
    func allMembers(saveFolder: URL) async -> [LibraryItem] {
        let folder = libraryFolder(for: .allFiles, saveFolder: saveFolder)
        await reconcile(folder: folder)
        guard let (db, key) = await database() else { return [] }
        await drainPendingIfPossible(into: db, key: key)
        let folderKey = folder.standardizedFileURL.path
        let rows = (try? db.rows(inFolder: folderKey)) ?? []
        return makeLibraryItems(rows: rows, section: .allFiles, search: "", now: Date())
    }

    /// Count of items in `section` (ignoring search/in-memory filters) — the
    /// baseline "M" for the sidebar Info "N of M" readout.
    func sectionTotalCount(section: LibrarySection, saveFolder: URL) async -> Int {
        // Reuse the same section/saveFolder fetch the grid uses, with an empty
        // search, and return the count. (Cheap: rows are already reconciled/cached.)
        let rows = await items(section: section, saveFolder: saveFolder,
                               search: "", now: Date(), expandedTerms: nil)
        return rows.count
    }

    /// Bring DB rows for `folder` in sync with the filesystem (mtime-keyed):
    /// new/changed packages read their manifest once, vanished rows are
    /// pruned, unchanged files are skipped.
    func reconcile(folder: URL) async {
        guard let (db, key) = await database() else {
            os_log("reconcile: database unavailable for %{public}@", log: indexLog,
                   type: .default, folder.path)
            return
        }
        await repairSealCaptureDatesIfNeeded(folder: folder, db: db, key: key)
        let folderKey = folder.standardizedFileURL.path
        let scanned = scanCaptureFiles(in: folder)
        let known = (try? db.rows(inFolder: folderKey)) ?? []
        os_log("reconcile %{public}@: scanned=%d known=%d", log: indexLog, type: .default,
               folderKey, scanned.count, known.count)
        let knownByPath = Dictionary(uniqueKeysWithValues: known.map { ($0.path, $0) })
        // Force the full re-read only until this folder has had one. Reading
        // the flag on every pass is what turned a one-time migration into a
        // permanent full rescan; the sweep below is what the flag is for.
        let forceRemigration = db.needsSmartKeywordsRemigration
            && !remigratedFolders.contains(folderKey)
        defer { if forceRemigration { remigratedFolders.insert(folderKey) } }
        let present = Set(scanned.map { $0.0.standardizedFileURL.path })

        var changed = false
        // Rows added or removed, as opposed to re-read in place. `changed`
        // alone can't drive the notification: a `.seal` whose manifest is
        // unreadable keeps the fileSize == 0 "re-read me" sentinel, so it skips
        // the fast path and re-marks EVERY pass as changed — and a listener that
        // refreshes on that reconciles again, posting again, forever.
        var membershipChanged = false
        let stale = known.map(\.path).filter { !present.contains($0) }
        if !stale.isEmpty, (try? db.delete(paths: stale)) != nil {
            changed = true
            membershipChanged = true
        }

        for (url, mtime) in scanned {
            let path = url.standardizedFileURL.path
            // Tolerance: mtimes round-trip through REAL columns; sub-
            // millisecond drift must not look like a change (it would re-read
            // every manifest on every reconcile). Also re-read rows whose
            // file_size is still 0 (the sort-columns backfill sentinel: a real
            // capture is never 0 bytes), so pre-existing rows pick up
            // size/category exactly once after the upgrade.
            let isSeal = url.pathExtension.lowercased() == "seal"
            // Skip the fast-path only when: no smart-keywords re-migration is
            // pending (else every manifest must be re-read once so the per-manifest
            // CaptureMetadata decode migration moves old combined tags into
            // smartKeywords), the row is fresh, has a real file_size, and doesn't
            // still need a one-time dimensions/source-app backfill.
            if !forceRemigration,
               let row = knownByPath[path],
               abs(row.mtime.timeIntervalSince(mtime)) < 0.001, row.fileSize > 0,
               !needsDimensionBackfill(isSeal: isSeal, width: row.width) { continue }
            // readEntry is @MainActor here (encryption branch made it so) → await.
            let entry = await LibrarySearchIndex.readEntry(at: url, mtime: mtime)
            let isNewRow = knownByPath[path] == nil
            let action = reconcileDateAction(manifestReadable: entry != nil,
                                             isSeal: isSeal,
                                             hasExistingRow: knownByPath[path] != nil)
            os_log("reconcile changed %{public}@: readable=%d action=%{public}@ fav=%d",
                   log: indexLog, type: .default, url.lastPathComponent,
                   entry != nil ? 1 : 0, String(describing: action),
                   (entry?.isFavorite ?? false) ? 1 : 0)
            switch action {
            case .indexFromManifest:
                guard let entry else { break }
                do {
                    try db.upsert(CaptureIndexRow(
                        path: path, folder: folderKey, mtime: mtime,
                        captureDate: entry.captureDate ?? mtime,
                        userTitle: entry.userTitle, title: entry.title,
                        tags: entry.tags,
                        smartKeywords: entry.smartKeywords ?? [],
                        fileSize: captureFileSize(at: url),
                        category: entry.category,
                        isFavorite: entry.isFavorite ?? false,
                        status: entry.status ?? .new,
                        captureKind: entry.captureKind,
                        durationSeconds: entry.durationSeconds ?? 0,
                        collectionIDs: entry.collectionIDs ?? [],
                        width: entry.width ?? 0,
                        height: entry.height ?? 0,
                        sourceApp: entry.sourceApp), ocrText: entry.ocrText)
                    changed = true
                    if isNewRow { membershipChanged = true }
                } catch {
                    os_log("reconcile upsert FAILED %{public}@: %{public}@", log: indexLog,
                           type: .error, path, String(describing: error))
                }
            case .keepExistingDate:
                // Encrypted .seal whose manifest can't be read right now
                // (session locked / key unavailable). Keep the existing row's
                // stable capture date and title/tags/FTS — re-stamping a
                // filesystem date here would float a re-saved capture to the
                // front of the strip. Only refresh the mtime so we don't re-read
                // every reconcile.
                if (try? db.updateMtime(path: path, mtime: mtime)) != nil { changed = true }
            case .provisionalUntilReadable:
                // .seal with no row yet and an unreadable manifest (session
                // locked at launch). Index a PROVISIONAL row so it still lists,
                // dated by stat for now, with fileSize 0 — the "re-read me"
                // sentinel that makes every later reconcile retry until the
                // manifest is readable and ENTRY replaces this with the stable
                // capture date. (Don't leave it unindexed — that hides it until
                // a tab switch.)
                let created = (try? url.resourceValues(forKeys: [.creationDateKey])
                    .creationDate) ?? mtime
                if (try? db.upsert(CaptureIndexRow(
                    path: path, folder: folderKey, mtime: mtime,
                    captureDate: created, userTitle: nil, title: "", tags: [],
                    fileSize: 0, category: nil),
                    ocrText: "")) != nil {
                    changed = true
                    if isNewRow { membershipChanged = true }
                }
            case .legacyStatDate:
                // Genuine legacy .png, or a plain .mov/.mp4 recording saved
                // without the package wrapper: no manifest either way, so the
                // stat-level creation date is the best stable signal we have.
                let created = (try? url.resourceValues(forKeys: [.creationDateKey])
                    .creationDate) ?? mtime
                // A plain movie has no manifest to carry captureKind, so infer
                // it from the extension — without this the row reads as an
                // image and the Library shows a photo icon on a video.
                let plainMovieKind: CaptureKind? =
                    plainMovieExtensions.contains(url.pathExtension.lowercased())
                    ? .screenRecording : nil
                if (try? db.upsert(CaptureIndexRow(
                    path: path, folder: folderKey, mtime: mtime,
                    captureDate: created, userTitle: nil, title: "", tags: [],
                    fileSize: captureFileSize(at: url), category: nil,
                    captureKind: plainMovieKind),
                    ocrText: "")) != nil {
                    changed = true
                    if isNewRow { membershipChanged = true }
                }
            }
        }
        if changed { persistIfEncrypted(db: db, key: key) }
        if membershipChanged {
            NotificationCenter.default.post(name: .libraryIndexDidChange, object: folder)
        }
    }

    /// One-time repair: earlier builds dated `.seal` rows by their filesystem
    /// date whenever the manifest wasn't readable at reconcile (see
    /// `reconcileDateAction`). Re-saving a capture bumps that date, floating it
    /// to the front of the strip. This re-resolves the stable manifest
    /// `createdISO8601` for EVERY already-indexed `.seal` row and corrects any
    /// that drifted. Runs at most once per folder per launch; only marks itself
    /// complete once every `.seal` could be read, so a locked-at-launch library
    /// finishes on a later launch.
    /// Call when the encryption session unlocks. While locked, the date repair
    /// can't read `.seal` manifests, so it bails for that launch; clearing the
    /// per-launch guard lets the next reconcile re-attempt it now that
    /// manifests are readable, so stale capture dates resolve in one sweep
    /// rather than one-per-edit.
    func sessionDidUnlock() {
        repairAttemptedFolders.removeAll()
    }

    private func repairSealCaptureDatesIfNeeded(folder: URL, db: LibraryIndexDB, key: SymmetricKey?) async {
        let folderKey = folder.standardizedFileURL.path
        guard !repairAttemptedFolders.contains(folderKey) else { return }
        // v2: re-resolve EVERY .seal (v1 only checked rows whose date ≈ mtime,
        // which missed captures re-saved more than once).
        let flagKey = "captureDateRepair.v2.\(folderKey)"
        if UserDefaults.standard.bool(forKey: flagKey) {
            repairAttemptedFolders.insert(folderKey)
            return
        }
        repairAttemptedFolders.insert(folderKey)

        let rows = (try? db.rows(inFolder: folderKey)) ?? []
        var changed = false
        var allReadable = true
        for row in rows where row.path.lowercased().hasSuffix(".seal") {
            let url = URL(fileURLWithPath: row.path)
            guard let entry = await LibrarySearchIndex.readEntry(at: url, mtime: row.mtime) else {
                allReadable = false   // locked / unreadable now — retry next launch
                continue
            }
            // Authoritative stable date is the manifest's createdISO8601. If the
            // stored row drifted from it (a filesystem date stamped by an older
            // build), correct it so re-saving never reorders the strip again.
            if let manifestDate = entry.captureDate,
               abs(manifestDate.timeIntervalSince(row.captureDate)) >= 1.0 {
                if (try? db.updateCaptureDate(path: row.path, captureDate: manifestDate)) != nil {
                    changed = true
                }
            }
        }
        if changed { persistIfEncrypted(db: db, key: key) }
        if allReadable { UserDefaults.standard.set(true, forKey: flagKey) }
    }

    /// Strip listing for `folder`: reconcile (mtime-keyed), then return rows
    /// from the `coveringDays` most recent calendar days that have captures
    /// (so a stale library still fills the strip), newest first. Returns nil
    /// ONLY when the database cannot open — the caller falls back to a
    /// direct scan so a broken DB never empties the strip. An empty folder
    /// returns [].
    /// `recordingsFolder` is where screen recordings for this strip live and get
    /// merged in: the Recordings folder for the Recent strip, or the Deleted
    /// folder itself for the Deleted strip (trashed recordings sit there as video
    /// files alongside trashed captures). Nil = captures only.
    func stripItems(folder: URL, recordingsFolder: URL?,
                    coveringDays: Int, now: Date) async -> [StripItem]? {
        await reconcile(folder: folder)
        guard let (db, key) = await database() else { return nil }
        await drainPendingIfPossible(into: db, key: key)
        let folderKey = folder.standardizedFileURL.path
        // In the Deleted strip, order by when the file was trashed (its mtime,
        // which SealDeleter stamps to the delete time) rather than the original
        // capture date — so it reads as a recently-deleted-first list, matching
        // trashed recordings (which already sort by mtime) and the Library Trash.
        let isTrash = folder.lastPathComponent == SealDeleter.deletedSubfolderName
        let rows = (try? db.rows(inFolder: folderKey)) ?? []
        let captures = rows.map { row in
            StripItem(
                // Directory-form for .seal packages — selection, tile diffing,
                // and Show-in-Library all rely on URL equality with
                // contentsOfDirectory-sourced URLs (same rule as makeLibraryItems).
                url: URL(fileURLWithPath: row.path, isDirectory: false),
                // Recent strip: the ordering key is when the capture last
                // MATTERED to the user — its capture date, or the later moment
                // they opened it from outside the strip (`capture_activity`). This is
                // both the sort key and the window key, since `merged` derives
                // the recent-day window from the same field: keying the window on
                // capture date alone would leave an item the user just opened out
                // of the listing entirely, which is what the old front-pinned
                // tile was papering over. NOT the file's mtime — background
                // rewrites (visual-tag/OCR backfill, `derived.json`) would float
                // untouched captures to the front; see `reconcileDateAction`.
                captureDate: isTrash ? row.mtime : max(row.captureDate, row.activityAt),
                displayName: libraryDisplayName(for: row),
                // A video `.seal` (recording) is discriminated by captureKind — the
                // same derivation makeLibraryItems uses — so the strip shows its
                // play/duration affordance and media filter buckets it correctly.
                isVideo: row.captureKind == .screenRecording || row.captureKind == .importedVideo,
                // Carry the indexed duration so the tile draws its "m:ss" badge
                // directly (AVURLAsset can't read a `.seal` package). 0 means
                // "unknown" → nil, leaving the lazy loader as the fallback.
                durationSeconds: (row.captureKind == .screenRecording || row.captureKind == .importedVideo)
                    && row.durationSeconds > 0 ? row.durationSeconds : nil)
        }
        let recordings = recordingsFolder.map { RecordingsLibrary.items(in: $0) } ?? []
        return StripItem.merged(captures: captures, recordings: recordings,
                                coveringDays: coveringDays, now: now)
    }

    /// Record that the user brought `url` up from outside the recent strip (a
    /// Library open, a cross-item undo jump), so the strip lists and sorts it as
    /// recent. Index-only — the capture file is never written for a mere view.
    ///
    /// A no-op when the index is unavailable (locked session, broken DB): the
    /// strip then falls back to capture dates, which is the pre-existing
    /// behaviour rather than a new failure.
    func markActivity(url: URL, at date: Date = Date()) async {
        guard let (db, key) = await database() else { return }
        try? db.markActivity(path: url.standardizedFileURL.path, at: date)
        persistIfEncrypted(db: db, key: key)
    }

    /// Snapshot of the live tag vocabulary across the whole index. Returns an
    /// empty vocabulary when the index is unavailable (e.g. still locked), so
    /// callers never block manual tag entry on index state.
    func vocabulary() async -> TagVocabulary {
        guard let (db, _) = await database() else { return TagVocabulary(entries: []) }
        return TagVocabulary.build(from: db)
    }

    /// All user tags with usage counts (for the Library BY TAG facet). Empty on
    /// index-open failure. User `tags` only — the `tags` column holds nothing
    /// else: the schema-v4 SQL migration moved pre-split auto keywords into
    /// `smart_keywords`, and generators have written only `smartKeywords`
    /// since. (An earlier "safety net" also dropped any tag that appeared in
    /// ANY capture's smart keywords — that hid legitimate user tags whenever
    /// the same word was an auto keyword elsewhere, e.g. a hand-added "test".)
    func allTags() async -> [(tag: String, count: Int)] {
        guard let (db, _) = await database() else { return [] }
        return (try? db.allTags()) ?? []
    }

    // MARK: plumbing

    private func database() async -> (db: LibraryIndexDB, key: SymmetricKey?)? {
        let key = await keyProvider()
        let thumb = Self.thumb(key)
        if let box = dbBox, thumb == activeKeyThumb { return box.map { (db: $0, key: key) } }
        dbBox = nil
        let db: LibraryIndexDB?
        if let key {
            db = EncryptedIndexFile(databaseURL: databaseURL).load(key: key)
        } else if await encryptionEnabled() {
            // Encryption is ON but the session is locked. The plaintext index
            // holds OCR text, titles and tags, so it must NOT be opened here —
            // this branch previously fell through to the plaintext file and
            // served real search hits on a locked app.
            //
            // A plaintext index should not exist at all once encryption is on:
            // `EncryptedIndexFile.persist` deletes it after the first sealed
            // write, and `purgePlaintextIndex()` removes it when encryption is
            // switched on. But a crash between those two points leaves one
            // behind, so this refuses rather than trusting the file is gone.
            // An empty in-memory database keeps the Library usable (it lists
            // nothing while locked anyway) instead of failing open.
            db = try? LibraryIndexDB(inMemoryFrom: nil)
        } else {
            // Encryption genuinely off — plaintext on disk is the normal mode.
            db = LibraryIndexDB.openRecreatingOnFailure(at: databaseURL)
        }
        if let db { migrateLegacyJSON(into: db) }
        dbBox = .some(db)
        activeKeyThumb = thumb
        return db.map { (db: $0, key: key) }
    }

    /// Encrypt + write THIS db with THIS key (no-op in plain mode). The
    /// caller passes what it already holds — re-reading dbBox/keyProvider
    /// here would race with lock transitions on other tasks (actor
    /// reentrancy across the @MainActor hop).
    private func persistIfEncrypted(db: LibraryIndexDB, key: SymmetricKey?) {
        guard let key else { return }
        do {
            try EncryptedIndexFile(databaseURL: databaseURL).persist(db, key: key)
        } catch {
            os_log("sealed index persist failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }

    private static func thumb(_ key: SymmetricKey?) -> Data? {
        guard let key else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(
            for: Data("index-key-id".utf8), using: key))
    }

    /// Fold queued locked-capture entries into the index. Called from
    /// items(...) so the first post-unlock listing absorbs them. The enqueue
    /// side lands in Phase 2 with the lock UI.
    private func drainPendingIfPossible(into db: LibraryIndexDB, key: SymmetricKey?) async {
        guard pendingQueue.count > 0 else { return }
        guard let identity = await identityProvider() else { return }
        var drained = 0
        for entry in pendingQueue.drain(identity: identity) {
            if (try? db.upsert(entry.row, ocrText: entry.ocrText)) != nil { drained += 1 }
        }
        if drained > 0 {
            os_log("drained %d pending index entries", log: log, type: .info, drained)
            persistIfEncrypted(db: db, key: key)
        }
    }

    /// One-time seed from the legacy JSON search index, then delete it so the
    /// two can never diverge. Entries keep their mtime, so unchanged captures
    /// are NOT re-read on the next reconcile. Pre-v2 entries (nil captureDate)
    /// are skipped — reconcile re-reads those manifests once instead.
    private func migrateLegacyJSON(into db: LibraryIndexDB) {
        let entries = legacyIndex.load()
        guard !entries.isEmpty else { return }
        var migrated = 0
        for (path, entry) in entries {
            guard let captureDate = entry.captureDate else { continue }
            let row = CaptureIndexRow(
                path: path,
                folder: (path as NSString).deletingLastPathComponent,
                mtime: entry.mtime,
                captureDate: captureDate,
                userTitle: entry.userTitle,
                title: entry.title,
                tags: entry.tags)
            if (try? db.upsert(row, ocrText: entry.ocrText)) != nil { migrated += 1 }
        }
        try? FileManager.default.removeItem(at: legacyIndex.fileURL)
        os_log("migrated %d legacy index entries", log: log, type: .info, migrated)
    }
}

/// Load/persist an in-memory LibraryIndexDB to a SealedBlob file. The index
/// is a disposable cache: unreadable/corrupt sealed files are deleted and an
/// empty DB returned — reconcile rebuilds from the packages. (Unlike key
/// capsules, regenerating the index loses nothing.)
struct EncryptedIndexFile {
    let databaseURL: URL

    static func sealedURL(for databaseURL: URL) -> URL {
        databaseURL.appendingPathExtension("sealed")
    }

    var sealedURL: URL { Self.sealedURL(for: databaseURL) }

    func load(key: SymmetricKey) -> LibraryIndexDB? {
        let data: Data?
        if let raw = try? Data(contentsOf: sealedURL) {
            if let opened = try? SealedBlob.open(raw, with: key) {
                data = opened
            } else {
                os_log("sealed index unreadable, recreating", log: log, type: .error)
                try? FileManager.default.removeItem(at: sealedURL)
                data = nil
            }
        } else {
            data = nil
        }
        if let db = try? LibraryIndexDB(inMemoryFrom: data) { return db }
        try? FileManager.default.removeItem(at: sealedURL)
        return try? LibraryIndexDB(inMemoryFrom: nil)
    }

    func persist(_ db: LibraryIndexDB, key: SymmetricKey) throws {
        try FileManager.default.createDirectory(
            at: sealedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sealed = try SealedBlob.seal(try db.serialize(), with: key)
        try sealed.write(to: sealedURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: sealedURL.path)
        // The plaintext file must not coexist with the sealed one.
        try? FileManager.default.removeItem(at: databaseURL)
    }
}
