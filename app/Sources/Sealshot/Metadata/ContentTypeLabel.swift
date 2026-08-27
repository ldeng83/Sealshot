import Foundation

/// Friendly, read-only display label for a capture's auto-classified
/// `ScreenshotCategory`. `.other` has no meaningful label (returns nil so the
/// info panel omits the row). There is no `chart` category — that scene tag
/// was dropped in the visual-tagging work.
enum ContentTypeLabel {
    static func label(for category: ScreenshotCategory) -> String? {
        switch category {
        case .error: return "Error"
        case .code: return "Code"
        case .design: return "Design"
        case .document: return "Document"
        case .dashboard: return "Dashboard"
        case .chat: return "Conversation"
        case .settings: return "Settings"
        case .receipt: return "Receipt"
        case .other: return nil
        }
    }
}
