import CoreML
import CoreGraphics
import CoreVideo
import os.log

/// On-device TATR table **detector**. Loads the bundled FP16 Core ML model and
/// returns table bounding boxes in source-image normalized [0,1] top-left coords.
/// Never throws: any load/inference failure yields an empty array so callers can
/// fall back to geometry.
struct TATRDetector {
    private static let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "TATRDetector")
    private let model: MLModel?

    init() {
        guard let url = Bundle.main.url(forResource: TATRModelContract.modelName,
                                        withExtension: "mlmodelc") else {
            os_log("TATR model .mlmodelc not found in bundle", log: Self.log, type: .error)
            self.model = nil
            return
        }
        self.model = try? MLModel(contentsOf: url)
        if model == nil { os_log("TATR model failed to load", log: Self.log, type: .error) }
    }

    func detect(_ image: CGImage) -> [CGRect] {
        guard let model else { return [] }
        let w = TATRModelContract.inputWidth, h = TATRModelContract.inputHeight
        guard let pixelBuffer = Self.squishedPixelBuffer(image, width: w, height: h) else { return [] }
        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: [TATRModelContract.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
            let out = try model.prediction(from: input)
            guard let logitsArr = out.featureValue(for: TATRModelContract.logitsName)?.multiArrayValue,
                  let boxesArr = out.featureValue(for: TATRModelContract.boxesName)?.multiArrayValue
            else { return [] }
            let logits = Self.rows(logitsArr, cols: TATRModelContract.numClasses)
            let boxes  = Self.rows(boxesArr, cols: 4)
            let modelRects = DETRDecoder.decode(
                logits: logits, boxes: boxes,
                tableClassIndices: TATRModelContract.tableClassIndices,
                scoreThreshold: TATRModelContract.scoreThreshold,
                iouThreshold: TATRModelContract.iouThreshold)
            // Under squish preprocessing the per-axis scale cancels in normalized coords,
            // so model-space normalized boxes ARE source-image normalized — no inverse needed.
            return modelRects
        } catch {
            os_log("TATR inference failed: %{public}@", log: Self.log, type: .error,
                   error.localizedDescription)
            return []
        }
    }

    /// Flatten a (1, N, cols) MLMultiArray into `[[Float]]` of N rows.
    /// Uses NSNumber subscript (dtype-safe) to correctly read FLOAT16 storage.
    private static func rows(_ arr: MLMultiArray, cols: Int) -> [[Float]] {
        let total = arr.count
        guard cols > 0, total % cols == 0 else { return [] }
        let n = total / cols
        var result: [[Float]] = []
        result.reserveCapacity(n)
        for r in 0..<n {
            var row = [Float](repeating: 0, count: cols)
            for c in 0..<cols {
                // Multidimensional NSNumber subscript is stride-safe and dtype-safe
                // (FLOAT16 -> Float) regardless of the (1, N, cols) array's layout.
                row[c] = arr[[0, r, c] as [NSNumber]].floatValue
            }
            result.append(row)
        }
        return result
    }

    /// Draw `image` stretched to fill the entire `width`x`height` canvas (squish resize).
    /// No padding; each axis scales independently. The normalized box coordinates the model
    /// produces are already source-image normalized under this mapping — no inverse needed.
    private static func squishedPixelBuffer(_ image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        // CGContext origin is bottom-left; draw the image filling the entire canvas.
        // ctx.draw(image:in:) maps the image top-left to the rect's top-left when the
        // rect covers the full canvas, preserving upright orientation.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
