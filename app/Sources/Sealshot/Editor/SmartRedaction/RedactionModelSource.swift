import Foundation

/// Where the GLiNER2 FP16 model is fetched from and how to verify it. Hosted as
/// a GitHub release asset on the public Sealshot-Release repo (data, not app
/// code), lazy-downloaded on first use and verified against `sha256`.
struct RedactionModelSource {
    let url: URL
    let sha256: String   // lowercase hex SHA-256 of the zip
    let version: String  // install dir is versioned; bump => re-download

    static let current = RedactionModelSource(
        // This repo's own Releases page — the old Sealshot-Release repo WAS
        // transferred and renamed into this one, so the asset is native here
        // and the URL shipped in older builds redirects to the same bytes.
        url: URL(string: "https://github.com/ldeng83/Sealshot/releases/download/gliner2-fp16-v1/gliner2-fp16.zip")!,
        sha256: "ebb842b21798ad2ba983058d78a7df98db6f14a4ba2fac13417400b1273c70fa",
        version: "gliner2-fp16-v1")
}

/// Resolves on-disk locations for the downloaded model.
enum RedactionModelPaths {
    static func modelsRoot() -> String {
        return AppSupportDirectory.file("Models/gliner2-fp16").path
    }
    static func installDir(version: String) -> String { "\(modelsRoot())/\(version)" }
    /// Installed == the model weights sentinel exists in the versioned dir.
    static func isInstalled(version: String,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        fileExists(installDir(version: version) + "/model.safetensors")
    }
}
