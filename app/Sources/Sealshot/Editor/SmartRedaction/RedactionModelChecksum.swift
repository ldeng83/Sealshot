import Foundation
import CryptoKit

enum RedactionModelChecksum {
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = try handle.read(upToCount: 1 << 20) ?? Data(), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func matches(fileAt url: URL, expected: String) -> Bool {
        guard let got = try? sha256(ofFileAt: url) else { return false }
        return got.caseInsensitiveCompare(expected) == .orderedSame
    }
}
