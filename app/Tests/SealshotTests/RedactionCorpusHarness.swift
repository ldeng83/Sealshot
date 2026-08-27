import XCTest
import CoreGraphics
import ImageIO
@testable import Sealshot

/// Batch evaluation harness — NOT a regular test. Runs the full
/// `SmartRedactionAnalyzer` (Vision OCR + every deterministic layer; no
/// FM/engine) over every image in a directory and writes one report per
/// image, so detection coverage can be reviewed against the source images.
///
/// Skipped unless `REDACTION_CORPUS_DIR` is set (pass via
/// `TEST_RUNNER_REDACTION_CORPUS_DIR` with xcodebuild). Optional:
/// `REDACTION_CORPUS_FILTER` (filename substring),
/// `REDACTION_CORPUS_OUT` (report dir; defaults beside the corpus).
@MainActor
final class RedactionCorpusHarness: XCTestCase {

    func test_runCorpus() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["REDACTION_CORPUS_DIR"] else {
            throw XCTSkip("REDACTION_CORPUS_DIR not set — harness is opt-in")
        }
        // Deterministic floor only: the FM thorough pass is statistical and
        // would make report diffs noisy. Snapshot + restore the shared pref
        // (the test host shares the app container's defaults).
        let defaults = UserDefaults.standard
        let priorAI = defaults.object(forKey: "ai.enabled")
        defaults.set(false, forKey: "ai.enabled")
        defer {
            if let priorAI { defaults.set(priorAI, forKey: "ai.enabled") }
            else { defaults.removeObject(forKey: "ai.enabled") }
        }

        let dir = URL(fileURLWithPath: dirPath)
        let outDir = URL(fileURLWithPath: env["REDACTION_CORPUS_OUT"]
            ?? dir.appendingPathComponent("_reports").path)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let filter = env["REDACTION_CORPUS_FILTER"]

        let exts: Set<String> = ["png", "jpg", "jpeg", "webp", "avif", "heic", "tiff"]
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .filter { url in
                guard let f = filter, !f.isEmpty else { return true }
                return url.lastPathComponent.localizedCaseInsensitiveContains(f)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no images matched in \(dirPath)")

        let analyzer = SmartRedactionAnalyzer()
        for file in files {
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                try report(for: file, out: outDir, body: "LOAD FAILED\n")
                continue
            }
            do {
                // Opt-in raw OCR dump (line text + normalized box) for
                // diagnosing detector misses against real recognition output.
                if env["REDACTION_CORPUS_DUMP_OCR"] == "1" {
                    let layout = try await TextRecognizer().recognize(image)
                    let ocr = layout.lines.map {
                        String(format: "%.3f,%.3f,%.3fx%.3f|%@",
                               $0.box.minX, $0.box.minY, $0.box.width, $0.box.height, $0.text)
                    }.joined(separator: "\n")
                    try report(for: URL(fileURLWithPath: file.path + ".ocr"), out: outDir, body: ocr + "\n")
                }
                let result = try await analyzer.analyze(image, engine: nil)
                var lines = ["# \(file.lastPathComponent)  \(image.width)x\(image.height)  financial=\(result.financialDocument)  detections=\(result.detections.count)"]
                for d in result.detections.sorted(by: {
                    ($0.rects.first?.minY ?? 0, $0.rects.first?.minX ?? 0)
                        < ($1.rects.first?.minY ?? 0, $1.rects.first?.minX ?? 0)
                }) {
                    let label = d.customLabel ?? d.category.rawValue
                    let r = d.rects.first.map { String(format: "@%.0f,%.0f", $0.minX, $0.minY) } ?? ""
                    lines.append("\(d.category.rawValue)|\(label)|\(d.snippet)|rects=\(d.rects.count)\(r)")
                }
                try report(for: file, out: outDir, body: lines.joined(separator: "\n") + "\n")
            } catch {
                try report(for: file, out: outDir, body: "ANALYZE FAILED: \(error)\n")
            }
        }
    }

    private func report(for file: URL, out: URL, body: String) throws {
        let name = file.deletingPathExtension().lastPathComponent + ".txt"
        try body.write(to: out.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
