import Foundation
import GLiNER2Swift
import RedactionEngineInterface

/// Principal class loaded by the host app via NSBundle.
@objc(EnginePrincipal)
final class EnginePrincipal: NSObject, RedactionEngineProviding {
    @objc func makeEngine(modelPath: String) -> AnyObject? {
        // Load synchronously here (host calls off-main); nil on any failure.
        guard let engine = try? GLiNER2RedactionEngine(modelPath: modelPath) else { return nil }
        return engine
    }
}

final class GLiNER2RedactionEngine: RedactionEngine {
    private let model: GLiNER2

    init(modelPath: String) throws {
        // fromPretrained is async; block once at load (engine is created off-main).
        self.model = try awaitBlocking { try await GLiNER2.fromPretrained(modelPath) }
    }

    func detect(text: String, entityTypes: [String]) -> [EngineDetection] {
        let result = model.extractEntities(
            text: text,
            entityTypes: entityTypes,
            threshold: 0.5,
            includeConfidence: true,
            includeSpans: true
        )
        guard let entities = result["entities"] as? [String: Any] else { return [] }
        var out: [EngineDetection] = []
        for (label, value) in entities {
            guard let rows = value as? [[String: Any]] else { continue }
            for row in rows {
                guard let t = row["text"] as? String else { continue }
                let c = (row["confidence"] as? Double)
                    ?? (row["confidence"] as? Float).map(Double.init)
                    ?? 0.5
                out.append(EngineDetection(label: label, text: t, confidence: c))
            }
        }
        return out
    }
}

/// Run an async throwing operation to completion synchronously (engine load only).
private func awaitBlocking<T>(_ op: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task {
        do { result = .success(try await op()) }
        catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}
