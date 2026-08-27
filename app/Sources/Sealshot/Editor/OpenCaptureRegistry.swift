import Foundation

/// Tracks which capture `.seal` URLs are currently open in an editor window, so
/// background work (e.g. the metadata-pipeline auto-rename) can skip files the
/// user is actively editing and avoid desyncing the open window.
@MainActor
final class OpenCaptureRegistry {
    static let shared = OpenCaptureRegistry()
    private var paths = Set<String>()
    private func key(_ url: URL) -> String { url.standardizedFileURL.path }
    func add(_ url: URL) { paths.insert(key(url)) }
    func remove(_ url: URL) { paths.remove(key(url)) }
    func contains(_ url: URL) -> Bool { paths.contains(key(url)) }
}
