import AppKit
import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import os.log

extension Notification.Name {
    /// Posted (main thread) after an import mints library files; object is
    /// the imported `[URL]`. Drives the Import undo event (undo → trash).
    static let captureFilesImported = Notification.Name("com.seal-shot.captureFilesImported")
}

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "import")

/// Copies existing image files into the Library as `.seal` packages —
/// the import counterpart of `CaptureOutputWriter`. Originals are never
/// modified; names keep provenance ("invoice.png" → "invoice <timestamp>
/// .seal", de-collided); each import runs the same metadata pipeline as a
/// fresh capture.
///
/// Two phases so a progress UI can sit between them: `makePlan` (fast,
/// main-thread — resolves large-PDF prompts up front) and `execute`
/// (file I/O, runs anywhere, reports per-unit progress, checks
/// cancellation between units).
enum ImageImporter {

    /// Common Mac image formats — mirrors `EmptyCanvasView`'s drop list
    /// (minus `.seal`, which is already a Library document). All decode through
    /// the same ImageIO path (`decode`), except PDF (PDFKit). APNG files use the
    /// `.png` type and import as a static first frame.
    static let importableExtensions: Set<String> = Set([
        "png", "apng", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp",
        "webp", "avif", "ico", "pdf",
    ]).union(rawImageExtensions).union(importableVideoExtensions)

    /// Movie containers AVFoundation reliably opens — imported as unified
    /// video `.seal` packages (the same format the recorder writes).
    static let importableVideoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Common camera-RAW extensions (each conforms to `public.camera-raw-image`,
    /// which ImageIO decodes). Not exhaustive across every vendor body, but
    /// covers the mainstream ones; the open panel also accepts any file of the
    /// umbrella `UTType.rawImage`.
    static let rawImageExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf",
        "raf", "rw2", "orf", "pef", "raw", "3fr", "erf", "rwl", "srw", "x3f",
    ]

    /// The same formats as UTTypes, for the import open panel. `public.avif` has
    /// no static `UTType` constant, so it's resolved by identifier.
    static let importableContentTypes: [UTType] = [
        .png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .webP, .ico, .rawImage, .pdf,
        .movie, .quickTimeMovie, .mpeg4Movie,
    ] + [UTType("public.avif")].compactMap { $0 }

    /// Whether `url` is a file the importer accepts, by extension. This is the
    /// basis for the open panel's per-file enabling: under the app sandbox the
    /// panel's `allowedContentTypes` silently greys out some newer image UTIs
    /// (WebP, AVIF) even when they're listed and conform, so the panel enables
    /// by extension via its delegate instead. Directories are handled separately.
    static func isImportable(_ url: URL) -> Bool {
        importableExtensions.contains(url.pathExtension.lowercased())
    }

    /// PDFs beyond this many pages prompt before importing (each page
    /// becomes its own capture — a stray book shouldn't flood the Library).
    static let largePDFPageThreshold = 10

    /// Rasterization scale for PDF pages: 2x of the page's point size keeps
    /// text crisp on Retina displays.
    static let pdfRasterScale: CGFloat = 2

    enum ImportError: Error {
        case undecodable
    }

    struct Outcome {
        var imported: [URL] = []
        var failures: [(url: URL, error: Error)] = []
        /// True when `execute` stopped early via `isCancelled` — what's in
        /// `imported` already landed and stays.
        var cancelled = false
    }

    // MARK: Plan (fast, prompts resolved here)

    /// One source file's worth of work. A PDF counts one unit per page.
    enum Item {
        case image(URL)
        case pdf(URL, pages: Int)
        case video(URL)

        var units: Int {
            switch self {
            case .image, .video: return 1
            case .pdf(_, let pages): return pages
            }
        }

        var url: URL {
            switch self {
            case .image(let url): return url
            case .pdf(let url, _): return url
            case .video(let url): return url
            }
        }
    }

    struct Plan {
        var items: [Item] = []
        /// Files that failed during planning (unreadable PDFs).
        var failures: [(url: URL, error: Error)] = []
        var totalUnits: Int { items.reduce(0) { $0 + $1.units } }
    }

    /// Classify the picked files and resolve large-PDF prompts up front, so
    /// `execute` can run uninterrupted under a progress UI. Declining a
    /// large PDF skips it silently (a choice, not a failure).
    static func makePlan(
        _ urls: [URL],
        confirmLargeImport: (String, Int) -> Bool = { _, _ in true }
    ) -> Plan {
        var plan = Plan()
        for url in urls {
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                    plan.failures.append((url, ImportError.undecodable))
                    continue
                }
                let pages = document.pageCount
                if pages > largePDFPageThreshold,
                   !confirmLargeImport(url.lastPathComponent, pages) {
                    os_log("large PDF import declined: %{public}@ (%{public}d pages)",
                           log: log, type: .info, url.lastPathComponent, pages)
                    continue
                }
                plan.items.append(.pdf(url, pages: pages))
            } else if importableVideoExtensions.contains(url.pathExtension.lowercased()) {
                plan.items.append(.video(url))
            } else {
                plan.items.append(.image(url))
            }
        }
        return plan
    }

    // MARK: Execute (file I/O — off-main capable)

    /// Run a plan. `onUnitDone` fires after every finished unit with
    /// (completedUnits, totalUnits, sourceFilename); `isCancelled` is
    /// checked between units — already-imported packages stay. Metadata
    /// hooks fire per imported package via `startMetadata`.
    ///
    /// CPU-heavy work (decode, rasterize) is dispatched off the main actor
    /// via `Task.detached`; only `importImage` (which calls `writeSealPackage`),
    /// progress updates, and `startMetadata` run on the main actor.
    @MainActor
    static func execute(
        _ plan: Plan,
        saveFolder: URL,
        filenameFormat: String,
        includeTitle: Bool = true,
        now: Date = Date(),
        isCancelled: () -> Bool = { false },
        onUnitDone: (Int, Int, String) -> Void = { _, _, _ in },
        startMetadata: (URL, String) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        outcome.failures = plan.failures
        do {
            try FileManager.default.createDirectory(
                at: saveFolder, withIntermediateDirectories: true)
        } catch {
            outcome.failures.append(contentsOf: plan.items.map { ($0.url, error) })
            return outcome
        }

        let total = plan.totalUnits
        var done = 0
        for item in plan.items {
            if isCancelled() { outcome.cancelled = true; break }
            switch item {
            case .image(let url):
                do {
                    // Decode off the main actor — pure CPU work.
                    let image = try await Task.detached(priority: .userInitiated) {
                        try decode(url)
                    }.value
                    let basename = url.deletingPathExtension().lastPathComponent
                    let destination = try importImage(
                        image, subject: basename, saveFolder: saveFolder,
                        filenameFormat: filenameFormat, includeTitle: includeTitle, now: now)
                    outcome.imported.append(destination)
                    startMetadata(destination, basename)
                } catch {
                    os_log("import failed for %{public}@: %{public}@",
                           log: log, type: .error, url.path, String(describing: error))
                    outcome.failures.append((url, error))
                }
                done += 1
                onUnitDone(done, total, url.lastPathComponent)

            case .video(let url):
                do {
                    let basename = url.deletingPathExtension().lastPathComponent
                    let destination = try await importVideo(
                        url, subject: basename, saveFolder: saveFolder,
                        filenameFormat: filenameFormat, includeTitle: includeTitle, now: now)
                    outcome.imported.append(destination)
                    // No startMetadata: the image pipeline's OCR/tags don't
                    // apply — video summaries generate lazily (background
                    // pass / first play), like recordings.
                } catch {
                    os_log("video import failed for %{public}@: %{public}@",
                           log: log, type: .error, url.path, String(describing: error))
                    outcome.failures.append((url, error))
                }
                done += 1
                onUnitDone(done, total, url.lastPathComponent)

            case .pdf(let url, let pages):
                let basename = url.deletingPathExtension().lastPathComponent
                guard let document = PDFDocument(url: url) else {
                    outcome.failures.append((url, ImportError.undecodable))
                    done += pages
                    onUnitDone(done, total, url.lastPathComponent)
                    continue
                }
                for index in 0..<pages {
                    if isCancelled() { outcome.cancelled = true; break }
                    do {
                        // Rasterize off the main actor — CPU-heavy CGContext work.
                        let image = try await Task.detached(priority: .userInitiated) {
                            guard let page = document.page(at: index),
                                  let img = rasterize(page) else {
                                throw ImportError.undecodable
                            }
                            return img
                        }.value
                        let subject = pages == 1 ? basename : "\(basename) p\(index + 1)"
                        let destination = try importImage(
                            image, subject: subject, saveFolder: saveFolder,
                            filenameFormat: filenameFormat, includeTitle: includeTitle, now: now)
                        outcome.imported.append(destination)
                        startMetadata(destination, subject)
                    } catch {
                        os_log("PDF page %{public}d import failed for %{public}@: %{public}@",
                               log: log, type: .error, index + 1, url.path,
                               String(describing: error))
                        outcome.failures.append((url, error))
                    }
                    done += 1
                    onUnitDone(done, total, url.lastPathComponent)
                }
            }
            if outcome.cancelled { break }
        }
        os_log("import finished: %{public}d imported, %{public}d failed%{public}@",
               log: log, type: .info, outcome.imported.count, outcome.failures.count,
               outcome.cancelled ? " (cancelled)" : "")
        return outcome
    }

    /// Async one-shot: plan + execute without cancellation UI. Kept for
    /// callers/tests that don't need a cancellation handle.
    @MainActor
    static func importFiles(
        _ urls: [URL],
        saveFolder: URL,
        filenameFormat: String,
        includeTitle: Bool = true,
        now: Date = Date(),
        confirmLargeImport: (String, Int) -> Bool = { _, _ in true },
        startMetadata: (URL, String) -> Void
    ) async -> Outcome {
        let plan = makePlan(urls, confirmLargeImport: confirmLargeImport)
        return await execute(plan, saveFolder: saveFolder, filenameFormat: filenameFormat,
                             includeTitle: includeTitle, now: now, startMetadata: startMetadata)
    }

    /// Import a movie file as a unified video `.seal` package (the same
    /// format the recorder writes): probe duration/size/audio for the
    /// manifest, grab a poster frame, and package a COPY of the movie —
    /// the source file is the user's, never consumed. Mirrors
    /// SharePackageImporter.depositVideo.
    @MainActor
    static func importVideo(
        _ url: URL,
        subject: String,
        saveFolder: URL,
        filenameFormat: String,
        includeTitle: Bool = true,
        now: Date = Date()
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: saveFolder, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        var frameSize = CGSize.zero
        if let track = (try? await asset.loadTracks(withMediaType: .video))?.first {
            frameSize = (try? await track.load(.naturalSize)) ?? .zero
        }
        // No decodable video track → not actually a movie; a real failure,
        // not a zero-sized import.
        guard frameSize != .zero else { throw ImportError.undecodable }
        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
        let thumbnail = await RecordingThumbnail.frame(for: url)
            .flatMap { try? CaptureOutputWriter.encodePNG($0) }

        let fmt = ISO8601DateFormatter()
        let stamp = fmt.string(from: now)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: stamp, modifiedISO8601: stamp,
            sourceSize: SealManifest.Size(width: Int(frameSize.width),
                                          height: Int(frameSize.height)),
            sourceApp: nil, enhanceParams: nil,
            captureKind: .importedVideo,
            video: VideoInfo(durationSeconds: duration, hasAudio: hasAudio))

        // VideoSealPackageIO.write CONSUMES its payload temp — feed it a
        // clone (O(1) on APFS), keeping the user's original untouched.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: temp)

        let effectiveSubject = CaptureConfig.importFilenameSubject(
            subject, includeTitle: includeTitle)
        let base = CaptureConfig.composeBase(
            subject: effectiveSubject, format: filenameFormat, at: now)
        let name = CaptureConfig.uniqueName(base: base, ext: "seal") { candidate in
            FileManager.default.fileExists(
                atPath: saveFolder.appendingPathComponent(candidate).path)
        }
        let destination = saveFolder.appendingPathComponent(name)
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.movie"
        let crypto = SealPackageCryptoContext.current()
        do {
            // Off-main: the encrypted path streams the whole payload through
            // AES-GCM — a long clip must not freeze the progress panel.
            try await Task.detached(priority: .userInitiated) {
                try VideoSealPackageIO.write(
                    to: destination, payloadTempURL: temp, originalUTI: uti,
                    manifest: manifest, thumbnailPNG: thumbnail, crypto: crypto)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return destination
    }

    /// Core single-image import: write `image` as a `.seal` named
    /// "<subject> <timestamp>" (de-collided) in `saveFolder`. Shared by the
    /// file importer and the New-from-Clipboard path.
    @MainActor
    static func importImage(
        _ image: CGImage,
        subject: String,
        saveFolder: URL,
        filenameFormat: String,
        includeTitle: Bool = true,
        now: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: saveFolder, withIntermediateDirectories: true)
        // Keep the original filename ("<name> <timestamp>") unless "include
        // title & app in filename" is off — then timestamp-only, so the
        // on-disk name can't leak the imported image's name (matches captures).
        // The flag is a parameter (production passes the preference) so tests
        // never inherit ambient defaults.
        let effectiveSubject = CaptureConfig.importFilenameSubject(
            subject, includeTitle: includeTitle)
        let base = CaptureConfig.composeBase(
            subject: effectiveSubject, format: filenameFormat, at: now)
        let name = CaptureConfig.uniqueName(base: base, ext: "seal") { candidate in
            FileManager.default.fileExists(
                atPath: saveFolder.appendingPathComponent(candidate).path)
        }
        let destination = saveFolder.appendingPathComponent(name)
        try writeSealPackage(
            to: destination, source: image, composite: image,
            annotations: [], crop: nil,
            crypto: SealPackageCryptoContext.current())
        return destination
    }

    // MARK: - Private

    /// Full-fidelity ImageIO decode (no downsampling — this becomes the
    /// package's immutable source.png). EXIF orientation is baked in so the
    /// source is always upright: `CGImageSourceCreateImageAtIndex` returns the
    /// raw sensor buffer, and a rotated photo (portrait phone shot stored
    /// landscape) would otherwise feed sideways pixels to display, OCR, tagging
    /// and redaction — where a rotated "6" misreads as "8".
    private static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { throw ImportError.undecodable }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init) ?? .up
        return orientedUpright(image, orientation)
    }

    /// Bake an EXIF orientation into the pixels, returning an upright image.
    /// `.up` is returned unchanged; any other value is rendered through a
    /// `CIImage.oriented(_:)` so width/height and pixels reflect the rotation.
    static func orientedUpright(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(oriented, from: oriented.extent) ?? image
    }

    /// Render one page at `pdfRasterScale` over an opaque white background
    /// (PDF pages are often transparent).
    private static func rasterize(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let w = max(1, Int(bounds.width * pdfRasterScale))
        let h = max(1, Int(bounds.height * pdfRasterScale))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: pdfRasterScale, y: pdfRasterScale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
