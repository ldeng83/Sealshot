import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// A Foundation Model tool that searches the screenshot library, so the chat can
/// answer questions about captures other than the open one.
@available(macOS 26, *)
struct LibrarySearchTool: Tool {
    let name = "searchLibrary"
    let description = "Search the user's screenshot library for captures whose title or on-screen text match a query. Returns matching titles and short text snippets."

    @Generable
    struct Arguments {
        @Guide(description: "Keywords to search the library for.")
        let query: String
    }

    let saveFolder: URL

    // Tool.Output is any PromptRepresentable; String qualifies, so return text.
    func call(arguments: Arguments) async throws -> String {
        let items = await LibraryIndexStore.shared.items(
            section: .allFiles, saveFolder: saveFolder, search: arguments.query, now: Date())
        let lines = items.prefix(5).map { item -> String in
            if let snippet = item.matchSnippet { return "- \(item.displayName): \(snippet)" }
            return "- \(item.displayName)"
        }
        return lines.isEmpty ? "No matching captures found." : lines.joined(separator: "\n")
    }
}

/// Stateful capture chat backed by the on-device Foundation Model. Seeds the
/// open capture's OCR text into the session instructions and exposes the
/// library-search tool. macOS 26+; constructed only behind an availability gate.
@available(macOS 26, *)
final class FoundationCaptureChatEngine: CaptureChatEngine {
    private let session: LanguageModelSession

    init(ocrText: String, saveFolder: URL, maxOCRChars: Int = 4_000) {
        let instructions = ChatPromptBuilder.instructions + "\n\n"
            + ChatPromptBuilder.captureContext(ocrText: ocrText, maxOCRChars: maxOCRChars)
        session = LanguageModelSession(tools: [LibrarySearchTool(saveFolder: saveFolder)],
                                       instructions: instructions)
    }

    func ask(_ question: String) async -> String {
        do {
            return try await session.respond(to: question).content
        } catch {
            return "Sorry — I couldn't answer that. Please try again."
        }
    }
}
#endif
