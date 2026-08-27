import Foundation
import os.signpost
import os.log

/// Thin wrapper around `OSSignposter` for capture-flow instrumentation.
///
/// Seven named spans cover the user-visible portions of a capture session:
/// - `hotkey-to-overlay`: ⌘⇧A / ⌘⇧S press → first overlay panel on-screen
/// - `selection-to-capture`: user completes selection → CGImage available
/// - `capture-to-output`: CGImage available → all writes (clipboard, file) complete
/// - `capture-to-preview-visible`: capture finished → floating preview on-screen
/// - `hotkey-to-picker`: ⌘⇧W press (or ⌘⇧A+space toggle) → first picker panel on-screen
/// - `picker-to-window-capture`: user clicks a window → CGImage available
/// - `hotkey-to-fullscreen-output`: ⌘⇧F press → clipboard + file writes complete
///
/// `end(_ token:)` also emits one `.debug`-level `os_log` line with the elapsed
/// milliseconds for the span, so PRD performance targets (<100ms overlay/picker,
/// <150ms preview/output) can be eyeballed in Console.
enum SignpostMetrics {
    static let signposter = OSSignposter(subsystem: "com.seal-shot.sealshot", category: "performance")
    private static let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "performance")

    struct Token {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        fileprivate let started: ContinuousClock.Instant
    }

    static func begin(_ name: StaticString) -> Token {
        Token(
            name: name,
            state: signposter.beginInterval(name),
            started: .now
        )
    }

    static func end(_ token: Token) {
        signposter.endInterval(token.name, token.state)
        let elapsed = ContinuousClock.now - token.started
        // Duration → milliseconds
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1.0e15
        os_log(
            "%{public}@ took %.1fms",
            log: log,
            type: .debug,
            "\(token.name)",
            ms
        )
    }
}
