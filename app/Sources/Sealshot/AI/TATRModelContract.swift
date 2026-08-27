import CoreGraphics

/// Single source of truth for the bundled TATR detection model's I/O contract
/// and detection thresholds. Values recorded from `scripts/convert_tatr.py` output;
/// thresholds tuned in the smoke task.
///
/// Model: microsoft/table-transformer-detection converted via coremltools 9.0 / torch 2.8.0
/// Recorded spec (from convert_tatr.py print output):
///   input  pixel_values: imageType RGB 800×1000
///   output logits:       multiArrayType FLOAT16 (1, 15, 3)
///   output pred_boxes:   multiArrayType FLOAT16 (1, 15, 4) — cx,cy,w,h normalized
enum TATRModelContract {
    static let modelName = "TATRDetection"      // .mlmodelc base name in the app bundle
    static let inputName = "pixel_values"        // ct.ImageType → CVPixelBuffer input
    static let inputWidth = 800
    static let inputHeight = 1000

    static let logitsName = "logits"             // MLMultiArray shape (1, Q, C)
    static let boxesName  = "pred_boxes"         // MLMultiArray shape (1, Q, 4), cxcywh normalized
    static let numQueries = 15                   // Q — microsoft/table-transformer-detection uses 15
    static let numClasses = 3                    // C — table (0), table-rotated (1), no-object (2)
    static let tableClassIndices: Set<Int> = [0, 1]  // 0=table, 1=table rotated

    static let scoreThreshold: CGFloat = 0.5     // 0.5; under squish preprocessing the balance-sheet fixture scores ~0.92
    static let iouThreshold: CGFloat = 0.3
    static let tokenInset: CGFloat = 0.01        // expand box when selecting edge tokens
}
