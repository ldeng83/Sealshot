import QuickLookThumbnailing
import AppKit

/// Finder thumbnails for `.seal` captures.
///
/// Without this a library folder is a wall of identical package icons, which
/// is the main reason browsing captures in Finder is unpleasant today. The
/// package already carries a 720px `thumbnail.png`, so for an unencrypted
/// capture this is a file read and a draw.
///
/// Encrypted captures produce no thumbnail — see `SealPackagePreview` for why
/// this process does not hold keys. Returning an error (rather than a
/// placeholder) lets Finder fall back to the app's own document icon, which is
/// the honest picture: there IS no preview available out here.
final class ThumbnailProvider: QLThumbnailProvider {
    enum PreviewError: Error { case noPreviewAvailable }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        guard let data = SealPackagePreview.imageData(in: request.fileURL,
                                                      preferComposite: false),
              let image = NSImage(data: data), image.size.width > 0
        else {
            handler(nil, PreviewError.noPreviewAvailable)
            return
        }

        // Fit inside the requested box, preserving aspect — Finder asks for a
        // square maximum and expects the reply to size itself.
        let max = request.maximumSize
        let scale = min(max.width / image.size.width, max.height / image.size.height, 1)
        let size = NSSize(width: (image.size.width * scale).rounded(),
                          height: (image.size.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else {
            handler(nil, PreviewError.noPreviewAvailable)
            return
        }

        handler(QLThumbnailReply(contextSize: size) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }, nil)
    }
}
