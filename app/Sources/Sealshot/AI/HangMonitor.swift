import Foundation
import os.log

private let hangLog = OSLog(subsystem: "com.seal-shot.sealshot", category: "hang")

/// Detects main-thread stalls ("app stuck" / beachball). A background queue pings
/// the main thread every `interval`; if the main thread doesn't acknowledge the
/// ping within `threshold`, it logs the stall (and how long it lasted). Logging
/// only — it never blocks, kills, or otherwise interferes with the app.
final class HangMonitor: @unchecked Sendable {

    static let shared = HangMonitor()

    private let queue = DispatchQueue(label: "com.seal-shot.hang-monitor", qos: .utility)
    private let interval: TimeInterval
    private let threshold: TimeInterval
    private var running = false

    init(interval: TimeInterval = 1.0, threshold: TimeInterval = 5.0) {
        self.interval = interval
        self.threshold = threshold
    }

    func start() {
        queue.async { [weak self] in self?.loop() }
    }

    func stop() { running = false }

    private func loop() {
        running = true
        while running {
            let sem = DispatchSemaphore(value: 0)
            let start = DispatchTime.now()
            DispatchQueue.main.async { sem.signal() }
            if sem.wait(timeout: .now() + threshold) == .timedOut {
                os_log("HangMonitor: main thread unresponsive for ≥ %{public}.0f s",
                       log: hangLog, type: .error, threshold)
                sem.wait()   // block until it recovers so we log once per stall
                let stalled = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                os_log("HangMonitor: main thread recovered after %{public}.1f s",
                       log: hangLog, type: .error, stalled)
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
