import XCTest
import Foundation
@testable import Sealshot

/// Clipboard-only destination makes captures ephemeral: the editor must not
/// open (⇧⌘N New-from-Clipboard covers deliberate editing).
final class ClipboardOnlyCaptureTests: XCTestCase {

    private let savedURL = URL(fileURLWithPath: "/tmp/x.seal")

    func test_clipboardOnly_doesNotOpenEditor() {
        XCTAssertFalse(CaptureCoordinator.shouldOpenEditor(output: .clipboard, savedFileURL: nil,
                                                          startedFromFloatingWindow: false))
    }

    func test_fileAndBoth_openEditor() {
        XCTAssertTrue(CaptureCoordinator.shouldOpenEditor(output: .file, savedFileURL: savedURL,
                                                          startedFromFloatingWindow: false))
        XCTAssertTrue(CaptureCoordinator.shouldOpenEditor(output: .both, savedFileURL: savedURL,
                                                          startedFromFloatingWindow: false))
    }

    func test_bothDegradedToClipboardOnFileFailure_stillOpensEditor() {
        // The editor is then the only place the capture survives beyond one paste.
        XCTAssertTrue(CaptureCoordinator.shouldOpenEditor(output: .both, savedFileURL: nil,
                                                          startedFromFloatingWindow: false))
    }
}
