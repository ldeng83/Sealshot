import Foundation
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "global-undo-timeline")

/// Persists `GlobalUndoStore`'s undo/redo stacks as a single JSON file, so the
/// app-global undo timeline survives quitting and relaunching. One file for
/// the whole app — mirrors `DeletionHistoryStore`'s structure exactly.
///
/// Sealed at rest whenever the encryption session vends a history key
/// (reusing the `.history` key purpose, same as `HistoryStore` and
/// `DeletionHistoryStore`). Failures never throw — persistence must not break
/// an undo/redo action.
struct GlobalUndoTimelineStore {

    /// The single JSON file holding both stacks.
    let fileURL: URL
    /// When non-nil and returning a key, the file is sealed at rest. A closure
    /// (not a key) so the session can rotate/lock without rebuilding the store.
    let keyProvider: (() -> SymmetricKey?)?

    init(fileURL: URL = GlobalUndoTimelineStore.defaultFileURL,
         keyProvider: (() -> SymmetricKey?)? = nil) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
    }

    /// Shared production instance, rooted under Application Support; sealed at
    /// rest whenever the encryption session vends a history key.
    /// MAIN-ACTOR ONLY: the key provider asserts main-actor isolation
    /// (`assumeIsolated`) and will trap if save/load runs off-main. Injected
    /// instances (tests) carry no such constraint.
    @MainActor
    static let shared = GlobalUndoTimelineStore(
        fileURL: defaultFileURL,
        keyProvider: {
            MainActor.assumeIsolated { try? EncryptionSession.shared.contentKey(for: .history) }
        })

    static var defaultFileURL: URL {
        AppSupportDirectory.file("undo-timeline.json")
    }

    /// Load the persisted stacks, or `nil` if none exists / it can't be
    /// decoded. Sealed files need the key; plaintext files always load.
    func load() -> GlobalUndoStore.Persisted? {
        guard var data = try? Data(contentsOf: fileURL) else { return nil }
        if SealedBlob.isSealed(data) {
            guard let key = keyProvider?(),
                  let opened = try? SealedBlob.open(data, with: key) else { return nil }
            data = opened
        }
        return try? JSONDecoder().decode(GlobalUndoStore.Persisted.self, from: data)
    }

    /// Persist both stacks, creating the directory on demand.
    func save(_ persisted: GlobalUndoStore.Persisted) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(persisted)
            if let key = keyProvider?() {
                data = try SealedBlob.seal(data, with: key)
            } else if let existing = try? Data(contentsOf: fileURL),
                      SealedBlob.isSealed(existing) {
                // No key but the file is sealed: a write here would silently
                // downgrade at-rest protection. Keep the sealed version.
                os_log("skipping undo-timeline save — file is sealed and no key is available",
                       log: log, type: .info)
                UndoDiag.note("global persist SKIPPED — sealed file, no key available")
                return
            }
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            os_log("undo-timeline save failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }
}
