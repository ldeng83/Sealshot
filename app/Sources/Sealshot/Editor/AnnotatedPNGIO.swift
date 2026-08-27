import AppKit
import ImageIO
import CoreServices
import UniformTypeIdentifiers

/// Read-side result of a Sealshot annotated PNG. `source` is nil for
/// non-Sealshot PNGs (raw captures, third-party files); callers fall back
/// to using `composite` as the canvas image in that case.
struct AnnotatedPNG {
    let composite: CGImage
    let source: CGImage?
    let annotations: [Annotation]
    let crop: CGRect?
    let focus: CGRect?
}

enum AnnotatedPNGIOError: Error {
    case destinationCreationFailed
    case sourceCreationFailed
    case finalizationFailed
    case sourceMetadataDecodeFailed
}

// XMP namespace + property paths embedded in the PNG.
private let sealshotNamespace = "https://sealshot.app/ns/1.0/" as CFString
private let sealshotPrefix    = "sealshot" as CFString
private let sourcePath        = "sealshot:Source"     as CFString
private let metadataPath      = "sealshot:Metadata"   as CFString

/// Write `composite` as a PNG file, embedding `source` (base64-encoded PNG)
/// and `metadataJSON` (the annotations JSON from `AnnotationCodec`) as
/// XMP metadata.
internal func writeAnnotatedPNG(
    composite: CGImage,
    source: CGImage,
    metadataJSON: Data,
    to url: URL
) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1, nil
    ) else {
        throw AnnotatedPNGIOError.destinationCreationFailed
    }

    let metadata = CGImageMetadataCreateMutable()
    CGImageMetadataRegisterNamespaceForPrefix(metadata, sealshotNamespace, sealshotPrefix, nil)

    let sourcePNGData = encodeCGImageToPNG(source)
    let sourceBase64 = sourcePNGData.base64EncodedString() as CFString
    CGImageMetadataSetValueWithPath(metadata, nil, sourcePath, sourceBase64)

    let metadataString = String(data: metadataJSON, encoding: .utf8) ?? ""
    CGImageMetadataSetValueWithPath(metadata, nil, metadataPath, metadataString as CFString)

    CGImageDestinationAddImageAndMetadata(destination, composite, metadata, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw AnnotatedPNGIOError.finalizationFailed
    }
}

/// Read a PNG file and try to extract Sealshot's embedded source +
/// annotations. Falls back gracefully for raw PNGs without the metadata.
internal func readAnnotatedPNG(url: URL) throws -> AnnotatedPNG {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw AnnotatedPNGIOError.sourceCreationFailed
    }
    guard let composite = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw AnnotatedPNGIOError.sourceCreationFailed
    }

    var sourceImage: CGImage? = nil
    var annotations: [Annotation] = []
    var crop: CGRect? = nil
    var focus: CGRect? = nil

    if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
        if let sourceValue = CGImageMetadataCopyStringValueWithPath(metadata, nil, sourcePath),
           let base64 = sourceValue as String?,
           let pngData = Data(base64Encoded: base64),
           let decoded = decodeCGImageFromPNG(pngData) {
            sourceImage = decoded
        }

        if let metaValue = CGImageMetadataCopyStringValueWithPath(metadata, nil, metadataPath),
           let json = metaValue as String?,
           let data = json.data(using: .utf8),
           let decoded = try? decodeAnnotations(from: data) {
            annotations = decoded.annotations
            crop = decoded.crop
            focus = decoded.focus
        }
    }

    return AnnotatedPNG(
        composite: composite,
        source: sourceImage,
        annotations: annotations,
        crop: crop,
        focus: focus
    )
}

// MARK: - Helpers

private func encodeCGImageToPNG(_ image: CGImage) -> Data {
    let mutableData = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        mutableData as CFMutableData,
        UTType.png.identifier as CFString,
        1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return mutableData as Data
}

private func decodeCGImageFromPNG(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
