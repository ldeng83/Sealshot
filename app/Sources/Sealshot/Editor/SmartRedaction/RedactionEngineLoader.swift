import Foundation
import os
import RedactionEngineInterface

private let logger = Logger(subsystem: "com.seal-shot.sealshot", category: "redaction")

/// Resolves and dynamically loads the arm64-only `SealshotRedactionEngine.bundle`
/// plugin at runtime. If any precondition fails (not Apple Silicon, no model file,
/// bundle absent, principal class mismatch) the method returns nil and the caller
/// falls back to the existing rule detectors.
final class RedactionEngineLoader {
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private var cached: RedactionEngine?

    /// Resolve the plugin engine, or nil (→ caller falls back to rule detectors).
    ///
    /// - Important: This method is **blocking** (the plugin's `makeEngine(modelPath:)`
    ///   loads the ML model synchronously, which can take ~1 s). Never call this on
    ///   the main actor or from a Swift-concurrency cooperative thread. Task 7 calls
    ///   it from a detached background task.
    func engine(modelPath: String?) -> RedactionEngine? {
        if let cached { return cached }

        // Normal/expected skips — no logging.
        guard Self.isAppleSilicon else { return nil }
        guard let modelPath else { return nil }
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }

        // From here on, all preconditions for a working engine are met.
        // Any nil below is unexpected — log each failure distinctly.
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
            logger.error("redaction engine: builtInPlugInsURL is nil")
            return nil
        }
        let url = plugInsURL.appendingPathComponent("SealshotRedactionEngine.bundle")

        guard let bundle = Bundle(url: url) else {
            logger.error("redaction engine: Bundle(url:) returned nil for plugin URL")
            return nil
        }
        guard bundle.load() else {
            logger.error("redaction engine: bundle.load() returned false")
            return nil
        }
        guard let cls = bundle.principalClass as? NSObject.Type else {
            logger.error("redaction engine: principalClass missing or not NSObject.Type")
            return nil
        }
        guard let provider = cls.init() as? RedactionEngineProviding else {
            logger.error("redaction engine: principal class does not conform to RedactionEngineProviding")
            return nil
        }
        guard let rawEngine = provider.makeEngine(modelPath: modelPath) else {
            logger.error("redaction engine: makeEngine(modelPath:) returned nil")
            return nil
        }
        guard let engine = rawEngine as? RedactionEngine else {
            logger.error("redaction engine: plugin loaded but as? RedactionEngine cast failed (cross-binary conformance)")
            return nil
        }

        cached = engine
        return engine
    }
}
