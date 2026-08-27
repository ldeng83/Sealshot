import Vision
import CoreGraphics
import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "barcode")

/// A QR/barcode detected in the displayed image, in normalized [0,1] top-left
/// space (Y-flipped from Vision's bottom-left). Vision-free for testability.
struct DetectedBarcode: Equatable {
    let payload: String
    let symbologyLabel: String
    /// Axis-aligned hull, normalized top-left origin (hit-testing fallback).
    let box: CGRect
    /// Tilt-following corners, normalized top-left origin (outline).
    let quad: TextQuad?

    /// An openable URL for the payload, or nil for plain text. Computed.
    var openableURL: URL? { BarcodeRecognizer.openableURL(for: payload) }
}

/// On-device QR/barcode detection. Wraps `VNDetectBarcodesRequest` and converts
/// observations into Vision-free `DetectedBarcode` values. Runs off the main
/// actor, mirroring `TextRecognizer`.
@MainActor
final class BarcodeRecognizer {

    func recognize(_ image: CGImage) async -> [DetectedBarcode] {
        let task = Task.detached(priority: .userInitiated) { recognizeSync(image) }
        return await task.value
    }

    /// Promote a payload to an openable URL, or nil. Accepts http(s)/mailto/tel
    /// schemes; promotes a bare `www.…` host to https. Plain text → nil.
    nonisolated static func openableURL(for payload: String) -> URL? {
        let s = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(),
           ["http", "https", "mailto", "tel"].contains(scheme) {
            return u
        }
        if s.lowercased().hasPrefix("www."), let u = URL(string: "https://\(s)") {
            return u
        }
        return nil
    }
}

/// Free function (no actor isolation) so it runs on the detached task.
private func recognizeSync(_ image: CGImage) -> [DetectedBarcode] {
    let request = VNDetectBarcodesRequest()
    guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
          let results = request.results else { return [] }
    let codes: [DetectedBarcode] = results.compactMap { obs in
        guard let payload = obs.payloadStringValue, !payload.isEmpty else { return nil }
        // Vision boundingBox is bottom-left origin; flip Y to top-left.
        let bb = obs.boundingBox
        let box = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
        let quad = TextQuad.fromVisionCorners(topLeft: obs.topLeft, topRight: obs.topRight,
                                              bottomLeft: obs.bottomLeft, bottomRight: obs.bottomRight)
        return DetectedBarcode(payload: payload, symbologyLabel: symbologyLabel(obs.symbology),
                               box: box, quad: quad)
    }
    os_log("detected %d barcode(s)", log: log, type: .info, codes.count)
    return codes
}

private func symbologyLabel(_ s: VNBarcodeSymbology) -> String {
    switch s {
    case .qr: return "QR"
    case .aztec: return "Aztec"
    case .pdf417: return "PDF417"
    case .dataMatrix: return "Data Matrix"
    case .code128: return "Code 128"
    case .ean13: return "EAN-13"
    case .ean8: return "EAN-8"
    case .upce: return "UPC-E"
    default: return "Barcode"
    }
}
