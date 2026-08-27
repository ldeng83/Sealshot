import AppKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "pen")

/// Field diagnostic for freehand stroke feel — "jelly", lag, wobble.
///
/// Three different faults produce the same complaint and have different fixes,
/// and unit tests cannot tell them apart because each one measures clean at the
/// bench: the geometry is stable in isolation, the tip lag is zero in isolation,
/// and the coordinate mapping is constant in a test. What they cannot model is
/// the running canvas — real sampling intervals, a zoom or scroll landing
/// mid-stroke, the view↔image mapping being recomputed per frame.
///
/// So this records, per frame of a live stroke:
///
///   * `lag`    — distance from the drawn tip to the newest raw point. Non-zero
///                means the ink trails the pointer and will spring forward.
///   * `drift`  — how far the ALREADY-DRAWN curve moved since the previous
///                frame, sampled at fixed absolute arc lengths from the start.
///                Non-zero is the curve re-solving behind your hand.
///   * `scale` / `origin` — the view↔image mapping. If these change mid-stroke
///                the whole stroke shifts on screen even with perfect geometry,
///                which no amount of curve work would fix.
///   * `dt`, `space` — frame interval and raw-sample spacing, i.e. how fast the
///                hand was moving and how densely the OS sampled it.
///
/// Per-frame lines are throttled (every 4th) because flattening the path to
/// measure drift is not free; the per-stroke summary is always written.
/// Mirrors `CanvasPasteDiag`: plain file, self-trims, inert under XCTest.
final class PenDiag: @unchecked Sendable {
    static let shared = PenDiag()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/pen.log")
    }

    static func note(_ message: String) { shared.write(message) }

    // MARK: - Per-stroke state (main thread only; a stroke is a UI gesture)

    @MainActor private static var frameIndex = 0
    @MainActor private static var strokeStart: CFAbsoluteTime = 0
    @MainActor private static var lastFrameAt: CFAbsoluteTime = 0
    @MainActor private static var prevSamples: [CGPoint] = []
    @MainActor private static var prevRawCount = 0
    @MainActor private static var maxLag: CGFloat = 0
    @MainActor private static var maxDrift: CGFloat = 0
    @MainActor private static var driftFrames = 0
    @MainActor private static var startScale: CGFloat = 0
    @MainActor private static var startOrigin: CGPoint = .zero
    @MainActor private static var mappingChanged = false

    /// Fixed distances (view units) at which the curve is compared frame to
    /// frame. Absolute, NOT fractions of length: the stroke grows, so a
    /// fraction names a different physical point each frame and would report
    /// ordinary growth as drift.
    private static let probeDistances: [CGFloat] =
        stride(from: CGFloat(10), through: 150, by: 10).map { $0 }

    @MainActor
    static func began(tool: String, scale: CGFloat, origin: CGPoint, strokeWidth: CGFloat) {
        frameIndex = 0
        strokeStart = CFAbsoluteTimeGetCurrent()
        lastFrameAt = strokeStart
        prevSamples = []
        prevRawCount = 0
        maxLag = 0
        maxDrift = 0
        driftFrames = 0
        startScale = scale
        startOrigin = origin
        mappingChanged = false
        note("── stroke begin | tool=\(tool) scale=\(fmt(scale))"
             + " origin=(\(fmt(origin.x)),\(fmt(origin.y))) strokeWidth=\(fmt(strokeWidth))")
    }

    /// Call once per live-preview draw, with the points and path actually used.
    @MainActor
    static func frame(rawViewPoints raw: [CGPoint], path: NSBezierPath,
                      scale: CGFloat, origin: CGPoint) {
        guard !raw.isEmpty else { return }
        frameIndex += 1
        let now = CFAbsoluteTimeGetCurrent()
        let dt = (now - lastFrameAt) * 1000
        lastFrameAt = now

        if scale != startScale || origin != startOrigin { mappingChanged = true }

        // Tip lag: how far the drawn end sits from the newest raw sample.
        let tip = path.isEmpty ? CGPoint.zero : path.currentPoint
        let lag = hypot(tip.x - raw[raw.count - 1].x, tip.y - raw[raw.count - 1].y)
        maxLag = max(maxLag, lag)

        // Raw sampling spacing — how fast the hand moved / how dense the OS was.
        let space: CGFloat = raw.count >= 2
            ? hypot(raw[raw.count - 1].x - raw[raw.count - 2].x,
                    raw[raw.count - 1].y - raw[raw.count - 2].y)
            : 0

        // Drift is the expensive one (flattening), so only on throttled frames.
        var drift: CGFloat = -1
        if frameIndex % 4 == 0 {
            let samples = sample(flatten(path), at: probeDistances)
            if let s = samples, let p = prevSamples as [CGPoint]?, p.count == s.count, !p.isEmpty {
                var worst: CGFloat = 0
                for i in 0..<s.count { worst = max(worst, hypot(s[i].x - p[i].x, s[i].y - p[i].y)) }
                drift = worst
                maxDrift = max(maxDrift, worst)
                driftFrames += 1
            }
            if let s = samples { prevSamples = s }

            note("  f\(frameIndex) raw=\(raw.count) (+\(raw.count - prevRawCount))"
                 + " space=\(fmt(space)) dt=\(fmt(CGFloat(dt)))ms"
                 + " lag=\(fmt(lag))"
                 + " drift=\(drift < 0 ? "-" : fmt(drift))"
                 + " segs=\(path.elementCount)"
                 + " scale=\(fmt(scale)) origin=(\(fmt(origin.x)),\(fmt(origin.y)))"
                 + (mappingChanged ? " MAPPING-CHANGED" : ""))
            prevRawCount = raw.count
        }
    }

    @MainActor
    static func ended(rawCount: Int, committed: Bool) {
        let ms = (CFAbsoluteTimeGetCurrent() - strokeStart) * 1000
        note("── stroke end | raw=\(rawCount) frames=\(frameIndex)"
             + " durMs=\(fmt(CGFloat(ms)))"
             + " MAXLAG=\(fmt(maxLag))"
             + " MAXDRIFT=\(driftFrames > 0 ? fmt(maxDrift) : "n/a")"
             + " driftSamples=\(driftFrames)"
             + " mappingChanged=\(mappingChanged ? "YES" : "no")"
             + " \(committed ? "committed" : "discarded")")
    }

    // MARK: - Geometry helpers

    private static func flatten(_ path: NSBezierPath) -> [CGPoint] {
        let flat = path.flattened
        var out: [CGPoint] = []
        var p = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &p) {
            case .moveTo, .lineTo: out.append(p[0])
            default: break
            }
        }
        return out
    }

    /// How far back from the drawing tip a probe must sit to count as part of
    /// the "already-drawn" line. The tip region is SUPPOSED to move, and
    /// including it made the first comparison of every stroke report 2-4 units
    /// of phantom drift the moment the curve first reached the furthest probe.
    private static let tipExclusion: CGFloat = 40

    /// Positions at fixed arc lengths from the start, or nil while the curve is
    /// too short for the furthest probe to be clear of the tip.
    private static func sample(_ pts: [CGPoint], at distances: [CGFloat]) -> [CGPoint]? {
        guard pts.count > 1, let furthest = distances.last else { return nil }
        var cum: [CGFloat] = [0]
        for i in 1..<pts.count {
            cum.append(cum[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        guard cum[cum.count - 1] >= furthest + tipExclusion else { return nil }
        return distances.map { target in
            var j = 1
            while j < cum.count && cum[j] < target { j += 1 }
            if j >= cum.count { return pts[pts.count - 1] }
            let span = cum[j] - cum[j - 1]
            let u = span > 0 ? (target - cum[j - 1]) / span : 0
            return CGPoint(x: pts[j - 1].x + (pts[j].x - pts[j - 1].x) * u,
                           y: pts[j - 1].y + (pts[j].y - pts[j - 1].y) * u)
        }
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }

    // MARK: - File writing (same shape as CanvasPasteDiag)

    private let lock = NSLock()
    private let disabled: Bool
    private let formatter: DateFormatter

    private init() {
        disabled = NSClassFromString("XCTestCase") != nil
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        write("────── session start | \(AppInfo.versionString)")
    }

    private func write(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message)
        guard !disabled else { return }
        lock.lock(); defer { lock.unlock() }

        let url = Self.logFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // Self-trim: past ~1 MB keep the newest ~300 KB.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > 1_000_000,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(300_000).write(to: url)
        }
        guard let data = "\(formatter.string(from: Date())) | \(message)\n".data(using: .utf8)
        else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
