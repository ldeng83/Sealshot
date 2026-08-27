import Foundation
import os.log

private let memLog = OSLog(subsystem: "com.seal-shot.sealshot", category: "memory")

/// A lightweight memory watchdog. Periodically samples the process footprint and,
/// when it crosses a high-water threshold, fires `onHighMemory` so the app can
/// pause/cancel background work (summary/OCR/video backfill) before the system
/// jetsams it. Hysteresis prevents repeated firing until the footprint recovers.
///
/// This contains the *symptom* of a leak/runaway; it is not a substitute for
/// fixing the cause, but it keeps the app alive and responsive.
@MainActor
final class MemoryGuard {

    static let shared = MemoryGuard()

    private let warnBytes: UInt64
    private let footprintProvider: () -> UInt64
    private var firedHigh = false
    private var timer: Timer?

    /// Called (once per crossing) when the footprint exceeds the threshold.
    var onHighMemory: (() -> Void)?

    /// `warnBytes` default 2.5 GB; `footprint` injectable for tests.
    init(warnBytes: UInt64 = 2_500_000_000,
         footprint: @escaping () -> UInt64 = MemoryGuard.footprint) {
        self.warnBytes = warnBytes
        self.footprintProvider = footprint
    }

    func start(interval: TimeInterval = 5) {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.evaluate() }
        }
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Pure decision (also the per-tick body): fires `onHighMemory` exactly once
    /// when the footprint first crosses `warnBytes`; re-arms only after it drops
    /// back below 75% of the threshold. Returns true on the firing tick.
    @discardableResult
    func evaluate() -> Bool {
        let fp = footprintProvider()
        if fp >= warnBytes {
            if !firedHigh {
                firedHigh = true
                os_log("MemoryGuard: footprint %{public}llu MB ≥ threshold %{public}llu MB — pausing background work",
                       log: memLog, type: .error, fp / 1_000_000, warnBytes / 1_000_000)
                onHighMemory?()
                return true
            }
        } else if fp < warnBytes * 3 / 4 {
            firedHigh = false
        }
        return false
    }

    /// Resident phys_footprint — the same number Xcode's memory gauge and the
    /// system's jetsam limit use.
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
