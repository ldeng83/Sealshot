import Foundation
import CryptoKit
import CommonCrypto

/// PBKDF2-HMAC-SHA256 derivation of a 256-bit key from a passphrase + salt.
/// Shared by `RecoveryKey` (recovery codes) and `SealSharePackage` (share passphrases).
enum PassphraseKDF {
    enum Error: Swift.Error { case emptyPassphrase, derivationFailed }

    static let defaultIterations = 600_000
    static let saltSize = 16

    static func makeSalt() -> Data {
        var salt = Data(count: saltSize)
        let status = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, saltSize, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return salt
    }

    /// `passphrase` is used verbatim; callers normalize beforehand if they need to.
    static func derive(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw Error.emptyPassphrase }
        var out = Data(count: 32)
        let pw = Array(passphrase.utf8)
        let status: Int32 = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.map { Int8(bitPattern: $0) }, pw.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw Error.derivationFailed }
        return SymmetricKey(data: out)
    }
}
