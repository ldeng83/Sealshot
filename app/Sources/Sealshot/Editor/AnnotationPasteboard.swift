import AppKit

/// Where a ⌘C should send its payload, given the current selection.
enum CopyTarget: Equatable {
    case objects      // copy the selected annotation objects
    case wholeImage   // composite the whole annotated image to the clipboard
}

/// ⌘C is context-sensitive: with a selection it copies objects, otherwise it
/// copies the whole image (the legacy behavior, also on the "Copy All" button).
func copyTarget(selectionCount: Int) -> CopyTarget {
    selectionCount > 0 ? .objects : .wholeImage
}

/// Clipboard payload: annotations plus the bitmap bytes any `.image`
/// members reference, so cross-document paste re-materializes assets.
struct AnnotationClipboardPayload: Codable, Equatable {
    var annotations: [Annotation]
    var assets: [String: Data] = [:]
}

/// Reads/writes annotation objects on an `NSPasteboard` under a private UTI.
/// Only Sealshot understands this type; it never collides with image/text data.
enum AnnotationPasteboard {
    static let type = NSPasteboard.PasteboardType("com.seal-shot.sealshot.annotations")

    static func write(_ payload: AnnotationClipboardPayload,
                      to pb: NSPasteboard = .general) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        pb.clearContents()
        pb.setData(data, forType: type)
    }

    static func read(from pb: NSPasteboard = .general) -> AnnotationClipboardPayload? {
        guard let data = pb.data(forType: type) else { return nil }
        if let payload = try? JSONDecoder().decode(AnnotationClipboardPayload.self,
                                                   from: data) {
            return payload
        }
        // Legacy bare [Annotation] array from older builds.
        if let annotations = try? JSONDecoder().decode([Annotation].self, from: data) {
            return AnnotationClipboardPayload(annotations: annotations)
        }
        return nil
    }
}
