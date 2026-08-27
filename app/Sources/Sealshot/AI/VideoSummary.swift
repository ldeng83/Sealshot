import Foundation

/// Pure helpers for whole-video summarization: where to sample frames, how to
/// drop duplicate OCR, and how to assemble the text handed to the model. The
/// AVFoundation / Vision / Foundation Model work lives in the editor controller;
/// this stays pure so the sampling and dedup logic is unit-testable.
enum VideoSummary {
    /// One sampled frame's recognized text.
    struct FrameText: Equatable {
        let timeSeconds: Double
        let text: String
    }

    /// Adaptive number of frames to sample, scaled to video length. Sub-linear
    /// (`coefficient · √seconds`) so coverage grows with duration but with
    /// diminishing density, clamped to `[minFrames, maxFrames]`. The default
    /// `coefficient` 1.3 makes a ~1-minute clip land near the old fixed ~6s
    /// density (10 frames); a ~10-minute video reaches the 24-frame ceiling.
    /// Zero for a non-positive duration.
    static func frameCount(durationSeconds duration: Double,
                           coefficient: Double = 1.3,
                           minFrames: Int = 4,
                           maxFrames: Int = 24) -> Int {
        guard duration > 0 else { return 0 }
        let raw = Int((coefficient * duration.squareRoot()).rounded())
        return min(maxFrames, max(minFrames, raw))
    }

    /// Frame sample times (seconds), spread across the whole video as segment
    /// midpoints — avoids the black first frame and the end-of-video grab
    /// failure. The frame count is adaptive (`frameCount`): short clips get a
    /// few samples, long ones sample end to end up to the ceiling. Empty for a
    /// non-positive duration.
    static func sampleTimes(durationSeconds duration: Double) -> [Double] {
        let count = frameCount(durationSeconds: duration)
        guard duration > 0, count > 0 else { return [] }
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }

    /// Drop frames whose text repeats the previous kept frame (screen
    /// recordings are static for long stretches) and frames with no text.
    /// Whitespace-normalized comparison.
    static func dedupe(_ frames: [FrameText]) -> [FrameText] {
        var out: [FrameText] = []
        var lastKept: String?
        for f in frames {
            let norm = normalized(f.text)
            guard !norm.isEmpty, norm != lastKept else { continue }
            out.append(f)
            lastKept = norm
        }
        return out
    }

    /// "[m:ss] text" per kept frame, joined, truncated to `maxChars` (the FM
    /// context budget).
    static func aggregate(_ frames: [FrameText], maxChars: Int = 4_000) -> String {
        let body = frames
            .map { "[\(timestamp($0.timeSeconds))] \($0.text)" }
            .joined(separator: "\n")
        return body.count <= maxChars ? body : String(body.prefix(maxChars))
    }

    /// "m:ss" for a time in seconds.
    static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    private static func normalized(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
