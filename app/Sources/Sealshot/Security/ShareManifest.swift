import Foundation

enum ShareEntryKind: String, Codable { case image, video }

struct ShareManifestEntry: Codable, Equatable {
    var name: String
    var kind: ShareEntryKind
    var uti: String
    var title: String?
    var tags: [String]
    var segmentIndex: Int   // 1-based index into the body segment list (0 is the manifest)
}

struct ShareCollectionDescriptor: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
}

struct ShareManifest: Codable, Equatable {
    var version: Int
    var note: String?
    var includesOriginal: Bool
    var entries: [ShareManifestEntry]
    /// v2: the collection this package represents (nil = plain multi-capture
    /// package). Optional key → pre-v2 packages decode to nil.
    var collection: ShareCollectionDescriptor? = nil
}
