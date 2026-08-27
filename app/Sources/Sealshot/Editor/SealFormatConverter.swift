import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "format-convert")

/// Converts legacy directory packages to single-file containers, in the
/// background, while the app is in use.
///
/// Deliberately NOT a launch-time bulk pass. A library can hold thousands of
/// captures and gigabytes of recordings; making someone wait for that before
/// the app is usable would be the wrong trade for a change they did not ask
/// for and cannot see. Everything reads both formats, so a half-converted
/// library is fully functional — which is what makes a lazy background sweep
/// viable at all.
///
/// The conversion itself is `writeSealPackage`/`VideoSealPackageIO.write`
/// reading a package and writing it back: those already emit containers, so
/// this coordinator's job is choosing what to convert and staying out of the
/// way while it does.
@MainActor
final class SealFormatConverter {
    static let shared = SealFormatConverter()

    private var task: Task<Void, Never>?
    /// The capture the editor currently has open. Converting it under the
    /// editor would rewrite the file an autosave is about to write to.
    private var skipURL: URL?

    private init() {}

    func start(saveFolder: URL) {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            await self?.run(saveFolder: saveFolder)
            await MainActor.run { self?.task = nil }
        }
    }

    func cancel() { task?.cancel(); task = nil }

    /// Tell the converter which capture is open so it can leave it alone.
    func setOpenCapture(_ url: URL?) { skipURL = url?.standardizedFileURL }

    /// Every legacy package still to convert, newest first — the captures
    /// someone is most likely to look at (and so most likely to benefit from
    /// a Finder thumbnail) become containers soonest.
    static func pendingPackages(in folders: [URL],
                                fileManager: FileManager = .default) -> [URL] {
        var pending: [(URL, Date)] = []
        for folder in folders {
            let entries = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for url in entries where url.pathExtension.lowercased() == "seal" {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }   // already a container
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                pending.append((url, mtime))
            }
        }
        return pending.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func run(saveFolder: URL) async {
        let folders = [
            saveFolder,
            saveFolder.appendingPathComponent(SealDeleter.deletedSubfolderName, isDirectory: true),
            ScratchCapture.folder(under: saveFolder),
        ]
        var converted = 0
        var failed = 0
        for url in Self.pendingPackages(in: folders) {
            if Task.isCancelled { return }
            if url.standardizedFileURL == skipURL { continue }
            do {
                try Self.convert(url)
                converted += 1
            } catch {
                // A package that will not convert is LEFT ALONE, still
                // readable in its old shape. One bad capture must never stop
                // the sweep, and must never cost the user the capture.
                failed += 1
                os_log("convert failed %{public}@: %{public}@", log: log, type: .error,
                       url.lastPathComponent, String(describing: error))
            }
            // Yield between packages: this is housekeeping and must never
            // compete with what the user is doing.
            await Task.yield()
        }
        if converted > 0 || failed > 0 {
            os_log("format conversion: %{public}d converted, %{public}d failed",
                   log: log, type: .info, converted, failed)
        }
    }

    /// Convert one package in place, preserving its modification date.
    ///
    /// Entries are moved across verbatim — including the sealed ones. The
    /// conversion never decrypts, so it runs whether or not the session is
    /// unlocked, and an encrypted capture's bytes are never in the clear.
    ///
    /// mtime is restored because the library index compares stored row mtimes
    /// against disk: bumping every package would make the whole library look
    /// edited and drag it through a needless re-index — and, for trashed
    /// items, would reset the retention clock.
    static func convert(_ url: URL, fileManager: FileManager = .default) throws {
        guard !SealContainer.isContainer(url) else { return }
        let entries = try sealEntryMap(at: url)
        guard !entries.isEmpty else { throw ConvertError.emptyPackage }

        // Captured and restored through stat/utimensat, NOT FileManager, which
        // truncates the fraction. `reconcile` allows 1ms of drift (mtimes
        // round-trip through REAL columns); losing up to a second sails past
        // that, so every converted package reads as CHANGED on every pass —
        // re-index, post, reload, reconcile, forever. Same trap, and same fix,
        // as `writeDerivedSidecar`.
        var before = stat()
        let haveStat = stat(url.path, &before) == 0
        let payload = url.appendingPathComponent(VideoSealPackageIO.Entry.payload)
        let hasStreamedPayload = fileManager.fileExists(atPath: payload.path)

        // Write beside the original, then swap: a crash mid-convert must leave
        // the old package intact rather than a half-written new one.
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).convert-\(UUID().uuidString)")
        do {
            if hasStreamedPayload {
                // A recording: stream the payload rather than loading it.
                var sources: [(name: String, source: SealContainer.Source)] =
                    entries.filter { $0.key != VideoSealPackageIO.Entry.payload }
                        .map { ($0.key, .data($0.value)) }
                sources.append((VideoSealPackageIO.Entry.payload, .file(payload)))
                try SealContainer.write(sources: sources, to: staging)
            } else {
                try SealContainer.write(entries: entries.map { ($0.key, $0.value) }, to: staging)
            }
            try fileManager.removeItem(at: url)
            try fileManager.moveItem(at: staging, to: url)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        if haveStat {
            var times = [before.st_atimespec, before.st_mtimespec]
            _ = utimensat(AT_FDCWD, url.path, &times, 0)
        }
    }

    enum ConvertError: Error { case emptyPackage }
}
