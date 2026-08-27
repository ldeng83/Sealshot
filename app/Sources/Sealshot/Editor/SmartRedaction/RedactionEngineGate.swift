import Foundation

/// Whether the GLiNER2 engine should be used for this scan. Pure for testing;
/// callers supply the live values (arch, AI toggle, model presence).
enum RedactionEngineGate {
    static func shouldUseEngine(appleSilicon: Bool, aiEnabled: Bool, modelPresent: Bool) -> Bool {
        appleSilicon && aiEnabled && modelPresent
    }
}
