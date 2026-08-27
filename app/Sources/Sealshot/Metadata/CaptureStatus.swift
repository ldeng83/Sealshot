import Foundation

/// A capture's triage status. Independent of the Favorite flag — a capture can
/// be favorited and `.reviewed` at once. `String` raw values persist in the
/// manifest and the Library index.
enum CaptureStatus: String, Codable, Equatable, CaseIterable {
    case new, reviewed, archived

    var displayLabel: String {
        switch self {
        case .new: return "New"
        case .reviewed: return "Reviewed"
        case .archived: return "Archived"
        }
    }
}

/// Resolves a manifest's workflow fields to concrete display/filter values,
/// treating the pre-v7 nil case as the defaults (not favorite, `.new`).
enum CaptureWorkflow {
    static func isFavorite(_ m: SealManifest) -> Bool { m.isFavorite ?? false }
    static func status(_ m: SealManifest) -> CaptureStatus { m.status ?? .new }
}
