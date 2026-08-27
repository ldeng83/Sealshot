import Foundation

/// How a `.seal` capture originated. `String` raw values are stable for
/// manifest persistence. (`screenRecording`/`importedVideo` are reserved for
/// the recordings sub-project and are never written by the image pipeline.)
enum CaptureKind: String, Codable, Equatable {
    case screenshot, importedImage, clipboard, newCanvas, screenRecording, importedVideo, liveCapture

    var displayLabel: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .importedImage: return "Imported image"
        case .clipboard: return "Clipboard"
        case .newCanvas: return "New canvas"
        case .screenRecording: return "Screen recording"
        case .importedVideo: return "Imported video"
        case .liveCapture: return "Live capture"
        }
    }
}

/// The screen-capture mode. Set only for screenshots; `nil` for imports,
/// clipboard, and new-canvas captures.
enum CaptureMode: String, Codable, Equatable {
    case area, window, fullScreen, scrolling

    var displayLabel: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .fullScreen: return "Full screen"
        case .scrolling: return "Scrolling"
        }
    }
}
