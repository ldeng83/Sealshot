import Foundation
import CryptoKit

struct LicenseVerifier {
    let publicKeys: [Int: Curve25519.Signing.PublicKey]

    init(publicKeys: [Int: Curve25519.Signing.PublicKey] = LicenseKeys.production) {
        self.publicKeys = publicKeys
    }

    /// Whole-file entry point — the only way a license activates. `fileText`
    /// is the complete `.sealshotlicense` contents (preamble + blob line):
    /// 1. Canonicalize, split into preamble + blob (see `LicenseFileFormat`).
    ///    No blob line, or an empty preamble (bare blob) → `.malformed`.
    /// 2. Base64-decode the blob → envelope JSON → verify the Ed25519
    ///    signature over the raw payload bytes (`verify(_:)` below).
    /// 3. Hash the preamble and compare to `payload.textHash` — mismatch
    ///    means the clear-text was edited or stripped → `.textTampered`.
    /// Bare envelope JSON (no preamble at all) has no `SEALSHOT1.` line to
    /// find, so it's rejected at step 1 the same way. Identity shown to the
    /// user must always come from the returned payload, never parsed back
    /// out of the preamble text.
    func verify(fileText: String) throws -> LicensePayload {
        let canonical = LicenseFileFormat.canonicalize(fileText)
        guard let (preamble, blobBase64) = LicenseFileFormat.splitPreambleAndBlob(canonical)
        else { throw LicenseError.malformed }
        guard let envelopeData = Data(base64Encoded: blobBase64),
              let license = try? JSONDecoder().decode(SignedLicense.self, from: envelopeData)
        else { throw LicenseError.malformed }
        let payload = try verify(license)
        guard LicenseFileFormat.textHash(preamble: preamble) == payload.textHash
        else { throw LicenseError.textTampered }
        return payload
    }

    /// Envelope-level verify: Ed25519 signature over the raw payload bytes.
    /// Doesn't know about the clear-text preamble — used internally by
    /// `verify(fileText:)` above, and directly by tests that only care
    /// about signature correctness.
    func verify(_ license: SignedLicense) throws -> LicensePayload {
        guard let key = publicKeys[license.key] else { throw LicenseError.unknownSigningKey }
        guard let payloadData = Data(base64Encoded: license.payload),
              let sig = Data(base64Encoded: license.sig)
        else { throw LicenseError.malformed }
        guard key.isValidSignature(sig, for: payloadData) else { throw LicenseError.badSignature }
        guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: payloadData)
        else { throw LicenseError.malformed }
        return payload
    }
}
