import Foundation

/// Pure description of the persistent menu-bar status item's contents for a
/// given state. Kept free of AppKit so it can be unit-tested; `MenuBarController`
/// renders these specs into an `NSStatusItem` / `NSMenu`.

enum MenuBarState: Equatable {
    case idle
    case recording(paused: Bool, elapsedSeconds: Int)
}

/// Identifies what a menu row does. `MenuBarController` maps these to the
/// capture/recording coordinator calls.
enum MenuBarAction: Equatable {
    case captureFullscreen, captureUnified, captureDelayed, captureScroll, captureSaveAs, captureLive
    case captureRepeat
    case recordScreen, recordSelection
    case openEditor, openLibrary, newFromClipboard, importImage
    case settings, checkForUpdates, lockNow, quit
    case pauseResume, stopRecording
}

/// App state the idle menu's conditional rows depend on, read fresh each time
/// the menu opens (it rebuilds via menuNeedsUpdate). Kept AppKit-free so the
/// row logic stays unit-testable.
struct MenuBarContext: Equatable {
    /// Sparkle exists in this build (Direct); hides Check for Updates… on MAS.
    var updatesSupported = false
    /// Sparkle is transiently ready to run a check (gates enabled, not existence).
    var updateCheckReady = false
    /// Enhanced security is on — the only state where Lock Now means anything;
    /// hidden entirely when off (user-picked behavior).
    var encryptionEnabled = false
    /// False while already locked → Lock Now shows but grays out.
    var sessionUnlocked = false
    /// The clipboard holds an image → New from Clipboard is enabled; grayed
    /// out otherwise (nothing to open).
    var clipboardHasImage = false
}

enum MenuBarIcon: Equatable {
    case appIconMono      // idle: the app icon artwork in monochrome
    case recordingDot     // recording: app icon badged with a red dot
}

/// One row: an actionable item, a disabled header (`action == nil`, `enabled ==
/// false`), or a separator.
struct MenuBarItemSpec: Equatable {
    var title: String
    var action: MenuBarAction?
    var isSeparator: Bool
    var enabled: Bool
    /// SF Symbol name shown before the title. `nil` for separators and headers.
    var icon: String?

    static func item(_ title: String, _ action: MenuBarAction, icon: String? = nil,
                     enabled: Bool = true) -> MenuBarItemSpec {
        MenuBarItemSpec(title: title, action: action, isSeparator: false, enabled: enabled,
                        icon: icon ?? MenuBarModel.defaultIcon(for: action))
    }
    static func header(_ title: String) -> MenuBarItemSpec {
        MenuBarItemSpec(title: title, action: nil, isSeparator: false, enabled: false, icon: nil)
    }
    static let separator = MenuBarItemSpec(title: "", action: nil, isSeparator: true,
                                           enabled: false, icon: nil)
}

enum MenuBarModel {
    static func icon(for state: MenuBarState) -> MenuBarIcon {
        switch state {
        case .idle: return .appIconMono
        case .recording: return .recordingDot
        }
    }

    static func elapsedString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// SF Symbol shown before each menu row, by action. `pauseResume` is
    /// overridden per state in `items(for:)` (play vs pause).
    static func defaultIcon(for action: MenuBarAction) -> String {
        switch action {
        case .captureUnified:    return "camera.viewfinder"
        case .captureFullscreen: return "display"
        case .captureDelayed:    return "timer"
        case .captureScroll:     return "scroll"
        case .captureRepeat:     return "arrow.triangle.2.circlepath.camera"
        case .captureLive:       return "square.stack.3d.up"
        case .captureSaveAs:     return "square.and.arrow.down"
        case .recordScreen:      return "record.circle"
        case .recordSelection:   return "selection.pin.in.out"
        case .openEditor:        return "square.and.pencil"
        case .openLibrary:       return "books.vertical"
        case .newFromClipboard:  return "clipboard"
        case .importImage:       return "photo.badge.plus"
        case .settings:          return "gearshape"
        case .checkForUpdates:   return "arrow.triangle.2.circlepath"
        case .lockNow:           return "lock"
        case .quit:              return "power"
        case .pauseResume:       return "pause.circle"
        // A plain square (not circled) so it can't read as a dot — matches
        // the HUD's square stop button.
        case .stopRecording:     return "stop.fill"
        }
    }

    static func items(for state: MenuBarState,
                      context: MenuBarContext = MenuBarContext()) -> [MenuBarItemSpec] {
        switch state {
        case .idle:
            // Soft lock: while locked, disable rows that open/edit existing or
            // decrypted content. Capture & recording stay enabled (they write a
            // write-only encrypted .seal).
            let locked = context.encryptionEnabled && !context.sessionUnlocked
            var rows: [MenuBarItemSpec] = [
                .item("Smart Capture", .captureUnified),
                .item("Save As Capture…", .captureSaveAs),
                .separator,
                .item("Full Screen Capture", .captureFullscreen),
                .item("Delayed Capture", .captureDelayed),
                .item("Scrolling Capture", .captureScroll),
                .item("Live Capture", .captureLive),
                .item("Repeat Last Capture", .captureRepeat),
                .separator,
                .item("Record Full Screen", .recordScreen),
                .item("Record Selection", .recordSelection),
                .separator,
                .item("Open Editor", .openEditor, enabled: !locked),
                .item("Open Library", .openLibrary, enabled: !locked),
                .item("New from Clipboard", .newFromClipboard,
                      enabled: context.clipboardHasImage && !locked),
                .item("Import Image…", .importImage, enabled: !locked),
                .separator,
                .item("Settings…", .settings, enabled: !locked),
            ]
            if context.updatesSupported {
                rows.append(.item("Check for Updates…", .checkForUpdates,
                                  enabled: context.updateCheckReady && !locked))
            }
            if context.encryptionEnabled {
                rows.append(.item("Lock Now", .lockNow, enabled: context.sessionUnlocked))
            }
            rows += [.separator, .item("Quit Sealshot", .quit)]
            return rows
        case let .recording(paused, elapsedSeconds):
            return [
                .header("Recording — \(elapsedString(elapsedSeconds))"),
                // Resume shows the record dot ("go back to recording") — a
                // play icon read as media playback, matching the HUD.
                .item(paused ? "Resume" : "Pause", .pauseResume,
                      icon: paused ? "record.circle" : "pause.circle"),
                .item("Stop Recording", .stopRecording),
            ]
        }
    }
}
