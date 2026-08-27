import Foundation

/// One Live Capture window's OCR result, tagged with the identity the manifest
/// already knows (`SceneLayer.app` / `.title` / `.z`).
struct SceneWindowText: Equatable {
    let app: String
    let title: String
    let z: Int
    let text: String
}

/// Assembling a scene's text from its windows.
///
/// A scene's `source` image is the display wallpaper — the readable content
/// lives in the per-window assets. Labelling each block by its window is what
/// lets the summary attribute content to the right app, and the label is taken
/// from the manifest so it can never be hallucinated.
enum SceneText {

    /// "App — Title", or just the app when the window has no title.
    static func label(app: String, title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? app : "\(app) — \(t)"
    }

    /// Labelled blocks, frontmost window first, blank-line separated.
    /// Windows with no readable text are omitted entirely — an empty heading
    /// would imply a window said something it didn't.
    static func aggregate(_ windows: [SceneWindowText], maxChars: Int = 8_000) -> String {
        let body = windows
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.z < $1.z }
            .map { "\(label(app: $0.app, title: $0.title))\n\($0.text)" }
            .joined(separator: "\n\n")
        return body.count <= maxChars ? body : String(body.prefix(maxChars))
    }
}
