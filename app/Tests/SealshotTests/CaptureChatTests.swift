import XCTest
@testable import Sealshot

final class CaptureChatTests: XCTestCase {

    func test_captureContext_includesOCR_andTruncates() {
        let ctx = ChatPromptBuilder.captureContext(ocrText: "Build failed: 3 errors", maxOCRChars: 4_000)
        XCTAssertTrue(ctx.contains("Build failed: 3 errors"))
        let big = ChatPromptBuilder.captureContext(ocrText: String(repeating: "z", count: 9_000),
                                                   maxOCRChars: 500)
        XCTAssertLessThan(big.count, 1_000)
    }

    func test_instructions_nonEmpty() {
        XCTAssertFalse(ChatPromptBuilder.instructions.isEmpty)
    }

    /// A fake engine echoes a canned reply, so we can test the view model's
    /// turn-taking without the model.
    private final class FakeEngine: CaptureChatEngine {
        func ask(_ question: String) async -> String { "answer to: \(question)" }
    }

    @MainActor
    func test_send_appendsUserThenAssistant_andClearsInput() async {
        let vm = CaptureChatViewModel(engine: FakeEngine())
        vm.input = "what is this?"
        vm.send()
        XCTAssertEqual(vm.input, "", "input clears on send")
        XCTAssertEqual(vm.messages.first?.role, .user)
        // Let the response Task run.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages.last?.role, .assistant)
        XCTAssertEqual(vm.messages.last?.text, "answer to: what is this?")
    }

    @MainActor
    func test_send_ignoresEmptyInput() {
        let vm = CaptureChatViewModel(engine: FakeEngine())
        vm.input = "   "
        vm.send()
        XCTAssertTrue(vm.messages.isEmpty)
    }
}
