import AppKit
import UniformTypeIdentifiers
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "editor")

@MainActor
final class EditorSaveCoordinator {
    enum SaveError: Error {
        case pngEncodingFailed
        case writeFailed(URL, underlying: Error)
        case saveFolderUnavailable(URL, underlying: Error)
    }

    private let config: CaptureConfig

    /// Serial queue for background autosave writes: PNG-encode + AES-GCM seal
    /// + atomic disk write run here so a 4K-screenshot save (~2s) never freezes
    /// the main thread. Serial so successive autosaves to the same package can't
    /// race the atomic write.
    private let ioQueue = DispatchQueue(label: "com.seal-shot.sealshot.autosave", qos: .utility)

    init(config: CaptureConfig) {
        self.config = config
    }

    /// Immutable bundle of everything the off-main write needs, snapshotted on
    /// the main thread. `@unchecked Sendable`: the members are CGImages and
    /// value types that are not mutated after capture, so handing them to the
    /// IO queue is safe even though CGImage isn't formally `Sendable`.
    private struct SaveSnapshot: @unchecked Sendable {
        let destination: URL
        let source: CGImage
        // Raw render inputs — the composite is rendered on the IO queue now
        // that `render()` is thread-safe, so even the ~120ms raster is off-main.
        let displayBase: CGImage
        let displayScale: CGFloat
        let decodedAssets: [String: CGImage]
        let annotations: [Annotation]
        /// DOC-space crop — feeds the composite render (annotations and
        /// displayBase live in the resized document space).
        let crop: CGRect?
        /// Content region shown when the canvas is grown (see EditorState).
        let contentClip: CGRect?
        let focus: CGRect?
        let enhanced: CGImage?
        let showingEnhanced: Bool
        let enhanceParams: EnhanceParams
        let assets: [String: Data]
        let crypto: SealPackageCryptoContext
        // Document resize (v8): `source` above is the PRISTINE image;
        // `persistCrop` is the crop in pristine space (what annotations.json
        // stores); `resizedSize` is the resample target (nil = native).
        let persistCrop: CGRect?
        let resizedSize: CGSize?
        // Background-removal alternate base + display flag.
        let cutout: CGImage?
        let showingCutout: Bool
        /// v9: solid fill drawn behind the base (nil = transparent).
        let backgroundFill: SerializableColor?
    }

    /// Background autosave. Only the `EditorState` reads (cheap value/CGImage
    /// captures) happen on the main thread; the composite render AND the heavy
    /// PNG-encode + encrypt + write all run on `ioQueue`, with `completion`
    /// delivered back on the main thread. Returns immediately — never blocks.
    func autosave(state: EditorState,
                  completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let snapshot = SaveSnapshot(
            destination: sealDestinationURL(for: state.sourceURL),
            source: state.persistedSourceImage,
            displayBase: state.persistedDisplayBase,
            displayScale: state.persistedDisplayScale,
            decodedAssets: state.decodedImageAssets(),
            annotations: state.annotations,
            crop: state.croppedRect,
            contentClip: state.contentClip,
            focus: state.focusRect,
            enhanced: state.enhancedImage,
            showingEnhanced: state.persistedShowingEnhanced,
            enhanceParams: state.enhanceParams,
            assets: state.imageAssets,
            crypto: SealPackageCryptoContext.current(),
            persistCrop: state.persistedCroppedRect,
            resizedSize: state.resizedSize,
            cutout: state.cutoutImage,
            showingCutout: state.showingCutout,
            backgroundFill: state.backgroundFill
        )
        ioQueue.async {
            let result: Result<URL, Error> = Self.renderAndWrite(snapshot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// The off-main half of `autosave`: render + encode + encrypt + write.
    /// `nonisolated` so the IO queue can call it; static so it cannot touch
    /// `@MainActor` state.
    private nonisolated static func renderAndWrite(_ s: SaveSnapshot) -> Result<URL, Error> {
        let composite = render(image: s.displayBase, annotations: s.annotations, crop: s.crop,
                               contentClip: s.contentClip,
                               scale: s.displayScale, focus: s.focus, assets: s.decodedAssets,
                               backgroundFill: s.backgroundFill)
        guard let compositeCG = nsImageToCGImage(composite) else {
            return .failure(SaveError.pngEncodingFailed)
        }
        do {
            let folder = s.destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeSealPackage(
                to: s.destination,
                source: s.source,
                composite: compositeCG,
                annotations: s.annotations,
                crop: s.persistCrop,
                contentClip: s.contentClip,
                focus: s.focus,
                resizedSize: s.resizedSize,
                cutout: s.cutout,
                showingCutout: s.showingCutout,
                backgroundFill: s.backgroundFill,
                enhanced: s.enhanced,
                showingEnhanced: s.showingEnhanced,
                enhanceParams: s.enhanceParams,
                assets: s.assets,
                crypto: s.crypto
            )
            return .success(s.destination)
        } catch {
            return .failure(SaveError.writeFailed(s.destination, underlying: error))
        }
    }

    /// `⌘S` — write a `.seal` package. If `state.sourceURL` is already a
    /// `.seal`, overwrite in place. If it's a legacy `.png` (or nil), write
    /// a new `.seal` next to it (or in `config.saveFolder` for nil) and
    /// return the new URL so the caller can reassign `state.sourceURL`.
    func save(state: EditorState) throws -> URL {
        let composite = render(
            image: state.persistedDisplayBase,
            annotations: state.annotations,
            crop: state.croppedRect,
            contentClip: state.contentClip,
            scale: state.persistedDisplayScale,
            focus: state.focusRect,
            assets: state.decodedImageAssets(),
            backgroundFill: state.backgroundFill
        )
        guard let compositeCG = compositeAsCGImage(composite) else {
            throw SaveError.pngEncodingFailed
        }
        let destination = sealDestinationURL(for: state.sourceURL)
        try ensureFolderExists(destination)
        do {
            try writeSealPackage(
                to: destination,
                source: state.persistedSourceImage,
                composite: compositeCG,
                annotations: state.annotations,
                crop: state.persistedCroppedRect,
                contentClip: state.contentClip,
                focus: state.focusRect,
                resizedSize: state.resizedSize,
                cutout: state.cutoutImage,
                showingCutout: state.showingCutout,
                backgroundFill: state.backgroundFill,
                enhanced: state.enhancedImage,
                showingEnhanced: state.persistedShowingEnhanced,
                enhanceParams: state.enhanceParams,
                assets: state.imageAssets,
                crypto: SealPackageCryptoContext.current()
            )
        } catch {
            throw SaveError.writeFailed(destination, underlying: error)
        }

        state.markClean()
        // Undo/redo persistence is owned by the app-global timeline
        // (`GlobalUndoStore`/`GlobalUndoTimelineStore`), not the package.
        os_log("editor save wrote %{public}@", log: log, type: .info, destination.path)
        return destination
    }

    /// `⌘C` — composite and write only to clipboard. Unchanged from the
    /// previous behavior.
    func copy(state: EditorState) throws {
        let composite = render(
            image: state.displayBase,
            annotations: state.annotations,
            crop: state.croppedRect,
            contentClip: state.contentClip,
            scale: state.displayScale,
            focus: state.focusRect,
            assets: state.decodedImageAssets()
        )
        guard let pngData = encodeCompositeAsPlainPNG(composite) else {
            throw SaveError.pngEncodingFailed
        }
        writeToClipboard(pngData)
    }

    // MARK: - Private

    private func compositeAsCGImage(_ composite: NSImage) -> CGImage? {
        nsImageToCGImage(composite)
    }

    private func encodeCompositeAsPlainPNG(_ composite: NSImage) -> Data? {
        guard let tiff = composite.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    private func writeToClipboard(_ pngData: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png], owner: nil)
        pb.setData(pngData, forType: .png)
        os_log("editor clipboard write %{public}d bytes", log: log, type: .info, pngData.count)
    }

    private func ensureFolderExists(_ destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        } catch {
            throw SaveError.saveFolderUnavailable(folder, underlying: error)
        }
    }

    /// Compute the `.seal` destination URL:
    /// - `.seal` source URL → return it unchanged (overwrite in place).
    /// - `.png` source URL → return same folder + same basename + ".seal".
    /// - nil source URL → return `config.saveFolder/<renderFilename .seal>`.
    private func sealDestinationURL(for sourceURL: URL?) -> URL {
        guard let source = sourceURL else {
            let name = config.renderFilename(extension: "seal")
            return config.saveFolder.appendingPathComponent(name)
        }
        let ext = source.pathExtension.lowercased()
        if ext == "seal" {
            return source
        }
        // .png (legacy) → swap extension, write a new .seal sibling.
        let base = source.deletingPathExtension().lastPathComponent
        let folder = source.deletingLastPathComponent()
        return folder.appendingPathComponent("\(base).seal")
    }
}

/// Extract a `CGImage` from a rendered composite. `nonisolated` free function
/// so the background autosave path can call it off the main thread.
///
/// The TIFF round-trip is deliberate: it normalizes to 1× pixels regardless of
/// any backing scale. (Now that `render()` produces an explicit 1× bitmap rep
/// this is belt-and-suspenders, but it's the cheapest robust extraction.)
func nsImageToCGImage(_ composite: NSImage) -> CGImage? {
    guard let tiff = composite.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return rep.cgImage
}
