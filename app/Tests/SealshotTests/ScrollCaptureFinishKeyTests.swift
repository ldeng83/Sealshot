import XCTest
import KeyboardShortcuts
@testable import Sealshot

/// The finish key for a scrolling-capture session: plain Return AND the
/// numeric-keypad Enter must both be bound for the session's duration (they
/// are different key codes — a Return-only binding leaves keypad Enter dead),
/// and both must be cleared at teardown so neither key is stolen system-wide
/// outside a session.
@MainActor
final class ScrollCaptureFinishKeyTests: XCTestCase {

    private func tinyImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testSessionBindsBothEnterKeys_andClearsThemAfter() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen in test environment") }
        let image = tinyImage()
        let controller = ScrollCaptureController(
            makeSampler: { _ in { image } },
            makeInjector: { _ in nil })   // no injector → manual mode, no event tap
        let region = SelectedRegion(
            globalRect: CGRect(x: 0, y: 0, width: 200, height: 200), screen: screen)

        let session = Task { await controller.run(region: region) }
        let deadline = Date().addingTimeInterval(2)
        while !controller.isRunning && Date() < deadline { await Task.yield() }
        XCTAssertTrue(controller.isRunning, "session failed to start")

        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .scrollCaptureFinish),
                       .init(.return, modifiers: []),
                       "main Return must finish the session")
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .scrollCaptureFinishKeypad),
                       .init(.keypadEnter, modifiers: []),
                       "keypad Enter must finish the session too")

        controller.cancelFromGlobalEsc()
        _ = await session.value
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .scrollCaptureFinish),
                     "Return binding must be cleared after the session")
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .scrollCaptureFinishKeypad),
                     "keypad Enter binding must be cleared after the session")
    }
}
