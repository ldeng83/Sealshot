import CoreMedia

/// Translates source PTS (host clock) to output PTS that excludes paused
/// intervals. `outputTime` returns nil for samples that arrive while paused
/// (the caller drops them). Pure value type.
struct RecordingClock {
    private let start: CMTime
    private var pausedTotal: CMTime = .zero
    private var pauseBegan: CMTime?

    init(start: CMTime) { self.start = start }

    var isPaused: Bool { pauseBegan != nil }

    mutating func pause(at time: CMTime) {
        guard pauseBegan == nil else { return }
        pauseBegan = time
    }

    mutating func resume(at time: CMTime) {
        guard let began = pauseBegan else { return }
        pausedTotal = pausedTotal + (time - began)
        pauseBegan = nil
    }

    /// Output PTS for a source sample, or nil if it falls within a pause.
    func outputTime(for source: CMTime) -> CMTime? {
        if let began = pauseBegan, source >= began { return nil }
        return (source - start) - pausedTotal
    }
}
