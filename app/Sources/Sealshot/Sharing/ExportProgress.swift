import Foundation

/// Lock-guarded cumulative byte counter: written off the main actor, read on main.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ n: Int64) { lock.lock(); value += n; lock.unlock() }
    var current: Int64 { lock.lock(); defer { lock.unlock() }; return value }
}

/// Pure fraction/ETA/formatting for export progress. Clock injected for tests.
struct ExportProgressMeter {
    let totalBytes: Int64
    let start: Date

    /// fraction in 0...1 (clamped); eta seconds, or nil until stable (>=3% AND >=1s elapsed).
    func sample(done: Int64, now: Date) -> (fraction: Double, eta: TimeInterval?) {
        guard totalBytes > 0 else { return (0, nil) }
        let f = min(1.0, max(0.0, Double(done) / Double(totalBytes)))
        let elapsed = now.timeIntervalSince(start)
        guard f >= 0.03, elapsed >= 1, f < 1 else { return (f, nil) }
        return (f, elapsed * (1 - f) / f)
    }

    /// "a few seconds left", "about 20s left", "about 3 min left", or nil.
    static func etaText(_ eta: TimeInterval?) -> String? {
        guard let eta, eta.isFinite, eta >= 0 else { return nil }
        if eta < 10 { return "a few seconds left" }
        if eta < 60 { return "about \(Int((eta / 5).rounded()) * 5)s left" }
        let mins = Int((eta / 60).rounded())
        return "about \(max(1, mins)) min left"
    }
}
