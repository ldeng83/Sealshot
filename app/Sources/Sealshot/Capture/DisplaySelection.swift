import Foundation

/// Which monitor a full-screen capture/recording targets. The index refers into
/// `NSScreen.screens`, kept index-based so the model + menu logic stay testable
/// without an `NSScreen`.
enum DisplayChoice: Equatable {
    case display(index: Int)
    case allDisplays
}

/// A display's user-facing facts, for building the picker menu.
struct DisplayDescriptor: Equatable {
    let index: Int
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// One entry in the per-pill display menu.
enum DisplayMenuItem: Equatable {
    case display(DisplayDescriptor)
    case allDisplays
    case chooseOnScreen
}

/// Pure builder for the display menu shown by the full-screen capture/record pill
/// chevrons. `allowAllDisplays` is true for image capture, false for recording
/// (ScreenCaptureKit records one display at a time).
enum DisplayMenuBuilder {
    static func items(_ displays: [DisplayDescriptor], allowAllDisplays: Bool) -> [DisplayMenuItem] {
        var items = displays.map(DisplayMenuItem.display)
        if allowAllDisplays { items.append(.allDisplays) }
        items.append(.chooseOnScreen)
        return items
    }
}
