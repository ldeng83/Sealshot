import Foundation

/// One turn in the capture chat.
struct AIChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

/// Pure instructions + context builder for the capture chat. No model
/// dependency — unit-testable on any OS.
enum ChatPromptBuilder {
    static let instructions = """
    You are a helpful assistant inside a screenshot app. Answer the user's \
    questions about the current screenshot using its on-screen text, included \
    below. When the user asks about other screenshots in their library, use the \
    searchLibrary tool. Be concise and base answers on the available text; if \
    it doesn't contain the answer, say so.
    """

    static func captureContext(ocrText: String, maxOCRChars: Int) -> String {
        "Current screenshot text (OCR):\n\(MetadataPromptBuilder.ocrExcerpt(ocrText, maxChars: maxOCRChars))"
    }
}

/// Engine the chat UI talks to. The concrete Foundation Model implementation is
/// macOS 26-only; this protocol keeps the view model OS-agnostic and testable.
protocol CaptureChatEngine: AnyObject {
    func ask(_ question: String) async -> String
}

/// Drives the chat panel: appends the user turn, awaits the engine, appends the
/// reply. OS-agnostic (engine is injected), so it's unit-testable with a fake.
@MainActor
@Observable
final class CaptureChatViewModel {
    private(set) var messages: [AIChatMessage] = []
    private(set) var isResponding = false
    var input: String = ""

    private let engine: any CaptureChatEngine
    init(engine: any CaptureChatEngine) { self.engine = engine }

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        messages.append(AIChatMessage(role: .user, text: question))
        input = ""
        isResponding = true
        Task { @MainActor in
            let answer = await engine.ask(question)
            messages.append(AIChatMessage(role: .assistant, text: answer))
            isResponding = false
        }
    }
}
