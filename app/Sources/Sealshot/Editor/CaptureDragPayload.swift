import AppKit
import UniformTypeIdentifiers

/// Renders a capture for drag-out to other apps (Finder, Mail, Slack, …):
/// - image `.seal` → flattened PNG exactly as exported: the (decrypted)
///   composite with the focus indicator baked in when the capture focuses a
///   sub-region — same look Quick Look shows.
/// - video `.seal` → the (decrypted) movie payload via `VideoExportWriter`.
/// - legacy non-package file → byte-for-byte copy.
/// Dropped filenames use the capture's display name. The crypto context is
/// snapshotted on the main actor at drag start, so the actual write can run
/// on a background promise queue while the unlocked session stays usable.
enum CaptureDragPayload {

    struct Source {
        let url: URL
        let displayName: String
        let isVideo: Bool
    }

    /// Whether the item can render right now — encrypted packages need the
    /// unlocked session's identity. Callers skip (and toast) locked items.
    @MainActor
    static func canExport(_ url: URL) -> Bool {
        !SealPackageCrypter.isLocked(url) || SealPackageCryptoContext.current().identity != nil
    }

    /// The promised file's type: PNG for images, the payload's container for
    /// videos (cheap manifest-only read — the payload is never touched), the
    /// file's own type for legacy non-package items.
    @MainActor
    static func fileType(for source: Source) -> UTType {
        guard source.isVideo else { return .png }
        guard source.url.pathExtension == "seal" else {
            return UTType(filenameExtension: source.url.pathExtension) ?? .movie
        }
        guard let contents = try? VideoSealPackageIO.read(
            at: source.url, crypto: SealPackageCryptoContext.current()) else { return .movie }
        return VideoExportWriter.outputType(for: contents).type
    }

    /// Whether this source can ONLY be handed over as a file promise, i.e. an
    /// eager render would block the drag gesture. True for an encrypted video
    /// payload (gigabytes to decrypt) and for a package we can't read.
    ///
    /// Cheap on purpose — a manifest-only read, the payload is never touched —
    /// so the drag source can pick its writer strategy WITHOUT rendering
    /// anything. Rendering first and discarding the result is exactly the waste
    /// this exists to avoid (see the strip's drag start).
    @MainActor
    static func requiresPromise(_ source: Source,
                                crypto: SealPackageCryptoContext? = nil) -> Bool {
        guard source.url.pathExtension == "seal" else { return false }  // drags as its own URL
        guard source.isVideo else { return false }                      // fast PNG render
        guard let contents = try? VideoSealPackageIO.read(
            at: source.url, crypto: crypto ?? SealPackageCryptoContext.current())
        else { return true }        // unreadable → let the promise path report it
        return contents.key != nil  // encrypted payload → decrypt after the drop
    }

    /// A REAL temp file for the drag, rendered eagerly at drag start — plain
    /// file-URL drags work everywhere promises don't: Terminal inserts the
    /// path, and the editor canvas inserts the image as an overlay object.
    /// nil when eager rendering would block the gesture (encrypted video
    /// payloads — gigabytes to decrypt), where the caller falls back to an
    /// async file promise.
    /// - image `.seal` → flattened PNG (fast, same render as the promise)
    /// - plaintext-payload video `.seal` → APFS clone of the movie (O(1))
    /// - legacy non-package file → the original URL itself
    @MainActor
    static func eagerFileURL(for source: Source) -> URL? {
        guard source.url.pathExtension == "seal" else { return source.url }
        let crypto = SealPackageCryptoContext.current()
        if source.isVideo {
            guard let contents = try? VideoSealPackageIO.read(at: source.url, crypto: crypto),
                  contents.key == nil else { return nil }   // encrypted → promise
            let out = VideoExportWriter.outputType(for: contents)
            let dest = uniqueTempDestination(
                named: "\(sanitizedBase(source.displayName)).\(out.ext)")
            // Stream the payload RANGE out: inside a container, copying
            // `payloadURL` would hand the receiver the whole archive.
            guard let dest, (try? contents.payload.stream(to: dest)) != nil
            else { return nil }
            return dest
        }
        let dest = uniqueTempDestination(named: fileName(for: source, type: .png))
        guard let dest, (try? write(source: source, crypto: crypto, to: dest)) != nil
        else { return nil }
        return dest
    }

    /// `<temp>/<uuid>/<name>` so the dropped file carries the display name.
    private static func uniqueTempDestination(named name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return dir.appendingPathComponent(name)
    }

    /// AppKit drag source (recent strip): one promise provider per item.
    /// CAUTION: `NSFilePromiseProvider.delegate` is WEAK — the caller must
    /// keep `retainer` alive until the dragging session ends (endedAt), or
    /// the promise dies silently and receivers refuse the drop.
    ///
    /// KNOWN AND DELIBERATE: a promise drag is accepted by Finder but REFUSED
    /// by apps that read only `public.file-url` (WeChat, and most non-Finder
    /// receivers) — the drag visibly bounces back. The workaround is to drop
    /// into Finder first, then drag that file onward.
    ///
    /// DEAD END — do not re-attempt (measured 2026-08-07): adding
    /// `public.file-url` to this provider as a `.promised` type, resolved at
    /// drop time from a background render, does NOT work. The type is
    /// advertised correctly (it even shows up as `NSFilenamesPboardType`), but
    /// the promised value never materializes — `readObjects(forClasses:
    /// [NSURL.self])` comes back EMPTY and `propertyList(forType: .fileURL)`
    /// is nil, with the sandbox layer logging "No sandbox extension entry in
    /// cache … flavor: public.file-url (error: -9)". It fails even in-process,
    /// before any receiver is involved.
    ///
    /// The deeper reason no lazy scheme can work: receivers inspect the
    /// pasteboard DURING the drag to decide whether to accept the drop, so a
    /// file produced at drop time is already too late. Handing these apps a
    /// real file means rendering it BEFORE the gesture starts — which for an
    /// encrypted video writes a decrypted copy to temp on every pickup,
    /// including drags the user abandons. That trade was considered and
    /// rejected: decrypt-after-drop is the property worth keeping, and the
    /// bounce at least tells the user the drop was refused.
    struct DragItem {
        let provider: NSFilePromiseProvider
        let retainer: AnyObject
    }

    /// Whether a drag must use file PROMISES rather than a plain file URL.
    ///
    /// Writers have to be HOMOGENEOUS — a drag mixing promises with plain
    /// file-URL items drops the plain ones — so this is decided once, for the
    /// whole drag, before anything is rendered. Promises for a multi drag (each
    /// write lands post-drop, trackable by the progress sheet) or when any item
    /// cannot be rendered eagerly at all (encrypted video).
    ///
    /// A single eagerly-renderable item keeps a plain file URL, because that is
    /// what works where promises don't: Terminal path insert, canvas insert,
    /// and any app that reads only `public.file-url`. Pure so the policy is a
    /// test rather than a drag session.
    static func needsPromises(count: Int, anyRequiresPromise: Bool) -> Bool {
        count >= 2 || anyRequiresPromise
    }

    /// A single-item drag that serves BOTH worlds: `public.file-url` for
    /// Terminal, the canvas and anything that reads only file URLs, plus the
    /// in-app capture-list identity so a sidebar collection drop still resolves
    /// the real `.seal`. The promise path carries the identity the same way
    /// (see `IdentityFilePromiseProvider`); this is its eager counterpart.
    static func identityURLItem(fileURL: URL, captureListData: Data) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setData(captureListData,
                     forType: NSPasteboard.PasteboardType(captureListTypeIdentifier))
        return item
    }

    @MainActor
    static func promiseItem(for source: Source, session: DragExportSession? = nil) -> DragItem {
        let type = fileType(for: source)
        let delegate = PromiseDelegate(source: source, type: type,
                                       crypto: SealPackageCryptoContext.current(),
                                       session: session)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        return DragItem(provider: provider, retainer: delegate)
    }

    /// Like `promiseItem`, but the provider ALSO writes the in-app capture-list
    /// identity (own-process) so a multi-file drag works for sidebar drops
    /// WITHOUT a separate identity-only item — which Finder rejects (it can make
    /// no file from it, so it refuses the whole drop). Used for the first item of
    /// a Library drag when that item is a promise.
    @MainActor
    static func identityPromiseItem(for source: Source, session: DragExportSession?,
                                    captureListData: Data) -> DragItem {
        let type = fileType(for: source)
        let delegate = PromiseDelegate(source: source, type: type,
                                       crypto: SealPackageCryptoContext.current(),
                                       session: session)
        let provider = IdentityFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.captureListData = captureListData
        return DragItem(provider: provider, retainer: delegate)
    }


    /// SwiftUI `.onDrag` provider (Library grid/list). Locked-and-encrypted
    /// items get an empty provider — the drag starts but drops nothing.
    /// Prefers a real temp file (Terminal paths, canvas insert — see
    /// `eagerFileURL`); encrypted videos fall back to an async file
    /// representation so the gesture never blocks on a decrypt.
    @MainActor
    static func itemProvider(for source: Source) -> NSItemProvider {
        let provider = NSItemProvider()
        guard canExport(source.url) else { return provider }
        // Register the eager temp file as a FILE REPRESENTATION with NO
        // `.openInPlace` — so Finder COPIES the real bytes instead of making an
        // alias to the temp path (which looked like a broken 968-byte export).
        // Same idiom as the encrypted-video path below, which copies correctly.
        if let fileURL = eagerFileURL(for: source) {
            let type = fileType(for: source)
            provider.suggestedName = fileURL.lastPathComponent
            provider.registerFileRepresentation(
                forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all
            ) { completion in
                completion(fileURL, false, nil)   // coordinated:false, not-in-place → receiver copies
                return nil
            }
            return provider
        }
        let type = fileType(for: source)
        let filename = fileName(for: source, type: type)
        provider.suggestedName = filename
        let crypto = SealPackageCryptoContext.current()
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all
        ) { completion in
            do {
                // Unique temp dir so the file can carry the display name.
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(filename)
                try write(source: source, crypto: crypto, to: dest)
                completion(dest, false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    // MARK: - In-app identity (sidebar drops)

    /// Same-app pasteboard type carrying the dragged captures' `.seal` URLs
    /// (JSON array of paths) — the file-URL side of a drag is a RENDERED temp
    /// file, useless for identity operations like "add to collection".
    static let captureListTypeIdentifier = "com.seal-shot.capture-list"
    static var captureListType: UTType { UTType(exportedAs: captureListTypeIdentifier) }

    static func captureListData(for urls: [URL]) -> Data {
        (try? JSONEncoder().encode(urls.map(\.path))) ?? Data()
    }

    static func captureURLs(fromListData data: Data) -> [URL] {
        ((try? JSONDecoder().decode([String].self, from: data)) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    /// Which dropped URLs a drop-to-import should actually import: everything
    /// EXCEPT our own files — drags that originate from a tile carry a temp
    /// render (under the system temp dir), and a stray drop of a library
    /// `.seal` onto itself must not duplicate it. Pure; unit-tested.
    static func importableDropURLs(_ urls: [URL], saveFolder: URL,
                                   tempDir: URL = FileManager.default.temporaryDirectory) -> [URL] {
        let save = saveFolder.standardizedFileURL.path
        let temp = tempDir.standardizedFileURL.path
        return urls.filter { url in
            let p = url.standardizedFileURL.path
            return !p.hasPrefix(save + "/") && p != save && !p.hasPrefix(temp)
        }
    }

    /// "Display Name.png" — sanitized for the filesystem.
    static func fileName(for source: Source, type: UTType) -> String {
        let ext = type.preferredFilenameExtension ?? (source.isVideo ? "mov" : "png")
        return "\(sanitizedBase(source.displayName)).\(ext)"
    }

    private static func sanitizedBase(_ name: String) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if base.hasPrefix(".") { base = "_" + base.dropFirst() }
        if base.isEmpty { base = "Capture" }
        return base
    }

    /// The actual render/copy — pure file I/O + CryptoKit + ImageIO, runs on
    /// the promise/provider background queue. `progress`/`isCancelled` drive the
    /// drag-export sheet for the SLOW (video) path; they default to no-ops so the
    /// fast image/copy paths (and callers that don't want progress) are unchanged.
    nonisolated static func write(source: Source, crypto: SealPackageCryptoContext,
                                  to dest: URL,
                                  progress: (Int, Int) -> Void = { _, _ in },
                                  isCancelled: () -> Bool = { false }) throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        guard source.url.pathExtension == "seal" else {
            try FileManager.default.copyItem(at: source.url, to: dest)
            return
        }
        if source.isVideo {
            try VideoExportWriter.export(packageURL: source.url, to: dest, crypto: crypto,
                                         progress: progress, isCancelled: isCancelled)
            return
        }
        guard var image = fullCompositeImage(for: source.url, crypto: crypto) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // A focused capture drags out as JUST the focus area — matching the
        // editor's Export to Image (render(focus:) crops the same way). The
        // bracket-baked full frame is a PREVIEW look (Quick Look), not an
        // export format.
        if let geo = previewFocusGeometry(for: source.url, crypto: crypto),
           let normalized = FocusPreviewIndicator.normalizedFocus(
               focus: geo.focus, visibleSize: geo.visibleSize) {
            image = FocusPreviewIndicator.imageCroppedToFocus(image, normalized: normalized)
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: dest)
    }

    private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        private let source: Source
        private let type: UTType
        private let crypto: SealPackageCryptoContext
        /// Shared across all promise items of one drag; drives the progress sheet
        /// + cancel. nil when the caller wants no progress UI.
        private let session: DragExportSession?

        init(source: Source, type: UTType, crypto: SealPackageCryptoContext,
             session: DragExportSession?) {
            self.source = source
            self.type = type
            self.crypto = crypto
            self.session = session
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                             fileNameForType fileType: String) -> String {
            CaptureDragPayload.fileName(for: source, type: type)
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider,
                                             writePromiseTo url: URL,
                                             completionHandler: @escaping (Error?) -> Void) {
            // The cancel flag is thread-safe (read directly here); item start /
            // progress / finish hop to the main actor to drive the sheet.
            let session = self.session
            if let session { Task { @MainActor in session.willStartItem() } }
            do {
                if let session, session.cancelFlag.isCancelled {
                    throw CancellationError()
                }
                try CaptureDragPayload.write(
                    source: source, crypto: crypto, to: url,
                    progress: { done, total in
                        guard let session else { return }
                        Task { @MainActor in session.reportProgress(done: done, total: total) }
                    },
                    isCancelled: { session?.cancelFlag.isCancelled ?? false })
                if let session { Task { @MainActor in session.itemFinished() } }
                completionHandler(nil)
            } catch {
                // Count a cancelled/failed item as done so the sheet still closes
                // once Finder resolves (or abandons) the remaining promises.
                if let session { Task { @MainActor in session.itemFinished() } }
                completionHandler(error)
            }
        }

        nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
            Self.queue
        }

        /// Serialized (one write at a time) so aggregate "N of M" progress stays
        /// coherent and parallel multi-GB video decrypts don't thrash disk/CPU.
        private static let queue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            q.maxConcurrentOperationCount = 1
            return q
        }()
    }
}

/// `NSFilePromiseProvider` that also advertises the in-app capture-list identity
/// type on the same pasteboard item, so one item serves BOTH Finder (the file
/// promise) and the Library sidebar (the identity) — avoiding a separate
/// identity-only item that Finder would reject.
private final class IdentityFilePromiseProvider: NSFilePromiseProvider {
    var captureListData: Data?
    private var identityType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(CaptureDragPayload.captureListTypeIdentifier)
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if captureListData != nil { types.append(identityType) }
        return types
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == identityType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == identityType ? captureListData : super.pasteboardPropertyList(forType: type)
    }
}
