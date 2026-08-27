import Foundation

/// A user-defined, manually-curated collection of captures. The durable record
/// (id/name/order) lives in the sealed `collections` file owned by
/// `CollectionStore`; membership lives per-capture in each .seal manifest
/// (`collectionIDs`). Renaming never touches member manifests (membership
/// references the stable `id`).
///
/// Named `CaptureCollection` (not `Collection`) to avoid shadowing Swift's
/// standard-library `Collection` protocol.
struct CaptureCollection: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var sortIndex: Int
}
