import Foundation

/// Pure transport math for the custom in-canvas video controls. No
/// AVFoundation / AppKit so it can be unit-tested directly: time labels,
/// scrubber fraction ↔ time mapping, seek clamping, and playback-speed cycling.
enum VideoPlaybackMath {

    /// `0:00`, `0:42`, `3:15`, or `1:02:05` once the duration reaches an hour.
    /// Non-finite or negative inputs render as `0:00`.
    static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Fraction `0...1` of `time` through `duration`. Zero/non-finite duration
    /// → 0 (no NaN), and the result is clamped into `0...1`.
    static func fraction(forTime time: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return min(1, max(0, time / duration))
    }

    /// Time for a scrubber fraction `0...1` of `duration`.
    static func time(forFraction fraction: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, fraction.isFinite else { return 0 }
        return min(1, max(0, fraction)) * duration
    }

    /// Clamp a seek target into `0...duration`.
    static func clampedSeek(_ target: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(duration, max(0, target))
    }

    /// Playback-speed presets offered by the speed control.
    static let speeds: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

    /// Next speed in the cycle. For an off-grid current rate, advances past the
    /// nearest preset so repeated taps always move forward and wrap around.
    static func nextSpeed(after current: Float) -> Float {
        if let idx = speeds.firstIndex(of: current) {
            return speeds[(idx + 1) % speeds.count]
        }
        // Off-grid: pick the first preset strictly greater, else wrap to the first.
        return speeds.first(where: { $0 > current }) ?? speeds[0]
    }

    /// `1×`, `1.25×`, `0.5×` — trims a trailing `.0`.
    static func speedLabel(_ speed: Float) -> String {
        let rounded = (speed * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))×"
        }
        return "\(rounded)×"
    }
}
