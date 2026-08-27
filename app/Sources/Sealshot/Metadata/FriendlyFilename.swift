import Foundation

/// Turns a display title into a safe default filename (no extension).
enum FriendlyFilename {
    /// Structural path chars become " - " (keeps word separation).
    private static let structural = CharacterSet(charactersIn: ":/\\")
    /// Non-structural filesystem illegals — dropped outright.
    private static let dropIllegal = CharacterSet(charactersIn: "?%*|\"<>")

    static func sanitize(_ title: String) -> String {
        let mapped = title.unicodeScalars.map { scalar -> String in
            if structural.contains(scalar) { return " - " }
            // Decorative symbols / emoji (✳, 📊, bullets, +, $, …) and the
            // remaining illegals are removed entirely.
            if dropIllegal.contains(scalar) || CharacterSet.symbols.contains(scalar) { return "" }
            return String(scalar)
        }.joined()
        // Collapse all whitespace/newlines to single spaces and trim.
        let collapsed = mapped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? "Screenshot" : collapsed
    }
}
