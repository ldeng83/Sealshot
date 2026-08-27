import Foundation

/// The user-facing name for a capture. The descriptive `<window/app> <timestamp>`
/// scheme lives in the filename itself (see `CaptureConfig.composeBase`), so the
/// display name is simply:
///
/// - the manual `userTitle` override, when set; otherwise
/// - the filename without its extension.
///
/// The OCR-derived `generatedTitle`/`confidence` in the manifest are intentionally
/// not consulted here — that pipeline still runs and stores its results, but it no
/// longer drives naming.
enum CaptureDisplayName {
    @MainActor
    static func resolve(for url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "seal",
              let manifest = try? SealMetadataStore.readManifest(at: url),
              let user = manifest.metadata?.userTitle,
              !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return filename }
        return user
    }
}
