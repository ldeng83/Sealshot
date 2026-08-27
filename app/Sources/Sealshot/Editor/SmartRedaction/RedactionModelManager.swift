import Foundation

protocol RedactionModelDownloading {
    func start(from url: URL, onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void)
    func cancel()
}

@MainActor
final class RedactionModelManager: ObservableObject {
    @MainActor static let shared = RedactionModelManager(downloader: RedactionModelURLSessionDownloader())

    enum State: Equatable {
        case notDownloaded, downloading(Double), verifying, installing, ready(String), failed(String)
    }
    @Published private(set) var state: State = .notDownloaded

    private let version: String
    private let root: String
    private let expectedSha256: String
    private let url: URL
    private let downloader: RedactionModelDownloading
    private let checksum: (URL) -> String   // injectable for tests

    init(version: String = RedactionModelSource.current.version,
         root: String = RedactionModelPaths.modelsRoot(),
         expectedSha256: String = RedactionModelSource.current.sha256,
         url: URL = RedactionModelSource.current.url,
         downloader: RedactionModelDownloading = RedactionModelURLSessionDownloader(),
         checksum: @escaping (URL) -> String = { (try? RedactionModelChecksum.sha256(ofFileAt: $0)) ?? "" }) {
        self.version = version; self.root = root; self.expectedSha256 = expectedSha256
        self.url = url; self.downloader = downloader; self.checksum = checksum
        refreshState()
    }

    func refreshState() {
        let sentinel = "\(root)/\(version)/model.safetensors"
        if FileManager.default.fileExists(atPath: sentinel) { state = .ready("\(root)/\(version)") }
        else if case .downloading = state {} else { state = .notDownloaded }
    }

    func start() {
        if case .ready = state { return }
        state = .downloading(0)
        downloader.start(from: url, onProgress: { [weak self] f in
            Task { @MainActor in if case .downloading = self?.state { self?.state = .downloading(f) } }
        }, onFinish: { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let tmp): try? self?.finishDownload(tempZip: tmp)
                case .failure(let e): self?.state = .failed(e.localizedDescription)
                }
            }
        })
    }

    /// Post-download pipeline: verify checksum → unzip + atomic install → ready.
    func finishDownload(tempZip: URL) throws {
        state = .verifying
        guard checksum(tempZip).caseInsensitiveCompare(expectedSha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: tempZip)
            state = .failed("Downloaded model failed verification."); return
        }
        state = .installing
        do {
            let path = try RedactionModelInstaller.install(zipAt: tempZip, version: version, into: root)
            try? FileManager.default.removeItem(at: tempZip)
            state = .ready(path)
        } catch {
            state = .failed("Could not install the model.")
        }
    }

    func cancel() { downloader.cancel(); if case .ready = state {} else { state = .notDownloaded } }

    func remove() {
        try? FileManager.default.removeItem(atPath: "\(root)/\(version)")
        state = .notDownloaded
    }
}
