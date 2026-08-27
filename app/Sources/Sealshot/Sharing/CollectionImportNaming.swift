import Foundation

/// Resolves the local name for an imported collection so an import never
/// mutates a collection the receiver already owns (decision B). A free name is
/// used as-is; a clash becomes "<name> (Imported)", then "<name> (Imported 2)"…
enum CollectionImportNaming {
    static func resolvedName(base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        let first = "\(base) (Imported)"
        if !existing.contains(first) { return first }
        var n = 2
        while existing.contains("\(base) (Imported \(n))") { n += 1 }
        return "\(base) (Imported \(n))"
    }
}
