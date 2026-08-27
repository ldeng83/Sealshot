import Foundation

enum RedactionModelInstallError: Error { case unzipFailed, weightsNotFound }

enum RedactionModelInstaller {
    static func install(zipAt zip: URL, version: String, into root: String) throws -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gliner-unzip-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RedactionModelInstallError.unzipFailed }

        // Find the directory that actually contains the weights (handles flat or nested zips).
        guard let weights = fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "model.safetensors" })
        else { throw RedactionModelInstallError.weightsNotFound }
        let payloadDir = weights.deletingLastPathComponent()

        let dest = "\(root)/\(version)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.moveItem(atPath: payloadDir.path, toPath: dest)   // atomic within same volume (Application Support)
        return dest
    }
}
