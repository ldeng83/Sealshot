import Foundation

final class RedactionModelURLSessionDownloader: NSObject, RedactionModelDownloading, URLSessionDownloadDelegate {
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private var task: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)?

    func start(from url: URL, onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        task = session.downloadTask(with: url)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten written: Int64,
                                totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        let progress = Double(written) / Double(expected)
        let cb = onProgress
        Task { @MainActor in cb?(progress) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let stable = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        do {
            try fm.moveItem(at: location, to: stable)
        } catch {
            let cb = onFinish
            Task { @MainActor in cb?(.failure(error)) }
            return
        }
        let cb = onFinish
        Task { @MainActor in cb?(.success(stable)) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let cb = onFinish
        Task { @MainActor in cb?(.failure(error)) }
    }
}
