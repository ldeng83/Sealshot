import Foundation

/// Resolves the local GLiNER2 model dir: an explicit `RedactionModelPath`
/// override (used for dev/testing), else the managed install dir for the current
/// model version when its weights are present, else nil.
enum RedactionModelLocator {
    static func localModelPath(defaults: UserDefaults = .standard,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if let p = defaults.string(forKey: "RedactionModelPath"), fileExists(p) { return p }
        let dir = RedactionModelPaths.installDir(version: RedactionModelSource.current.version)
        if fileExists(dir + "/model.safetensors") { return dir }
        return nil
    }
}
