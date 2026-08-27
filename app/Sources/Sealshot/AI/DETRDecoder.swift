import CoreGraphics
import Foundation

/// Decodes DETR object-detection outputs (per-query class logits + cxcywh boxes)
/// into table bounding boxes in target/model-space normalized [0,1] coords.
enum DETRDecoder {

    private struct Scored { let rect: CGRect; let score: CGFloat }

    static func decode(logits: [[Float]], boxes: [[Float]],
                       tableClassIndices: Set<Int>,
                       scoreThreshold: CGFloat,
                       iouThreshold: CGFloat) -> [CGRect] {
        var candidates: [Scored] = []
        for (i, row) in logits.enumerated() where i < boxes.count {
            let probs = softmax(row)
            guard let best = probs.indices.max(by: { probs[$0] < probs[$1] }) else { continue }
            guard tableClassIndices.contains(best) else { continue }
            let score = CGFloat(probs[best])
            guard score >= scoreThreshold else { continue }
            let b = boxes[i]
            guard b.count == 4 else { continue }
            let cx = CGFloat(b[0]), cy = CGFloat(b[1]), w = CGFloat(b[2]), h = CGFloat(b[3])
            let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            candidates.append(Scored(rect: rect, score: score))
        }
        return nms(candidates.sorted { $0.score > $1.score }, iouThreshold: iouThreshold)
            .map(\.rect)
    }

    private static func softmax(_ xs: [Float]) -> [Float] {
        guard let m = xs.max() else { return [] }
        let exps = xs.map { exp($0 - m) }
        let sum = exps.reduce(0, +)
        return sum > 0 ? exps.map { $0 / sum } : exps
    }

    private static func nms(_ sorted: [Scored], iouThreshold: CGFloat) -> [Scored] {
        var kept: [Scored] = []
        for cand in sorted where !kept.contains(where: { iou($0.rect, cand.rect) > iouThreshold }) {
            kept.append(cand)
        }
        return kept
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
