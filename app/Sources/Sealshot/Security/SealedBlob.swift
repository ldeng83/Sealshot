import Foundation
import CryptoKit

/// Versioned AES-256-GCM container for files at rest.
/// Layout: magic "SLSB" (4) | version (1) | AES.GCM combined (nonce 12 | ciphertext | tag 16).
enum SealedBlob {
    enum Error: Swift.Error { case notSealed, unsupportedVersion(UInt8), corrupt }

    static let magic = Data("SLSB".utf8)
    static let version: UInt8 = 1

    static func isSealed(_ data: Data) -> Bool {
        data.count > magic.count && data.prefix(magic.count) == magic
    }

    static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw Error.corrupt }
        return magic + [version] + combined
    }

    static func open(_ blob: Data, with key: SymmetricKey) throws -> Data {
        guard isSealed(blob) else { throw Error.notSealed }
        let body = blob.dropFirst(magic.count)
        guard let v = body.first else { throw Error.corrupt }
        guard v == version else { throw Error.unsupportedVersion(v) }
        let box = try AES.GCM.SealedBox(combined: body.dropFirst())
        return try AES.GCM.open(box, using: key)
    }
}
