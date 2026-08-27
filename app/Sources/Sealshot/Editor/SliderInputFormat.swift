import Foundation

/// Pure parsing/clamping for the editable slider input boxes. The unit (pt / %)
/// renders as a separate label, so `display` returns only the integer string.
enum SliderInputFormat {
    static func clamp(_ raw: String, min: Double, max: Double, fallback: Double) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let value = Double(trimmed) ?? fallback
        let clamped = Swift.min(max, Swift.max(min, value))
        return Int(clamped.rounded())
    }

    static func display(_ value: Double, unit: String) -> String {
        "\(Int(value.rounded()))"
    }
}
