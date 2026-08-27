import Foundation
import CommonCrypto

enum WinZipAES {
    /// Header ID 0x9901, AE-2, AES-256, store. Written in both local + central headers.
    static let extraField: [UInt8] = [0x01,0x99, 0x07,0x00, 0x02,0x00, 0x41,0x45, 0x03, 0x00,0x00]

    static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int, dkLen: Int) -> [UInt8] {
        let pw = password.map { Int8(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: dkLen)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(iterations),
            &out, out.count)
        precondition(status == kCCSuccess)
        return out
    }

    /// AES-256: derive 66 bytes → encKey(32) ‖ macKey(32) ‖ verify(2).
    static func deriveKeys(password: [UInt8], salt: [UInt8]) -> (aesKey: [UInt8], macKey: [UInt8], verify: [UInt8]) {
        let dk = pbkdf2(password: password, salt: salt, iterations: 1000, dkLen: 66)
        return (Array(dk[0..<32]), Array(dk[32..<64]), Array(dk[64..<66]))
    }

    /// Single 16-byte AES block, ECB, no padding.
    static func aesECB(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(block.count == 16 && key.count == 32)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let st = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                         CCOptions(kCCOptionECBMode), key, key.count, nil,
                         block, block.count, &out, out.count, &moved)
        precondition(st == kCCSuccess && moved == 16)
        return out
    }

    /// 16-byte counter block: low 8 bytes = k little-endian, high 8 = 0.
    static func counterBlock(_ k: UInt64) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: k.littleEndian) { src in for i in 0..<8 { b[i] = src[i] } }
        return b
    }

    /// WinZip AES-CTR. Keystream = AES-ECB over consecutive little-endian counter
    /// blocks (k=1,2,3…); processed in chunks with one reused CCCryptor. Byte-identical
    /// to per-block ECB (ECB has no chaining). Throws CancellationError if the task is cancelled.
    static func ctrEncrypt(_ plaintext: [UInt8], key: [UInt8],
                           onBytes: (@Sendable (Int64) -> Void)? = nil) throws -> [UInt8] {
        precondition(key.count == 32)
        var cryptor: CCCryptorRef?
        let cs = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                 CCOptions(kCCOptionECBMode), key, key.count, nil, &cryptor)
        precondition(cs == kCCSuccess, "CCCryptorCreate failed")
        defer { CCCryptorRelease(cryptor) }

        var ct = [UInt8](repeating: 0, count: plaintext.count)
        let blocksPerChunk = 4096                                   // 64 KiB keystream / call
        var counterBuf = [UInt8](repeating: 0, count: blocksPerChunk * 16)
        var keystream  = [UInt8](repeating: 0, count: blocksPerChunk * 16)
        var k: UInt64 = 0
        var i = 0
        while i < plaintext.count {
            if Task.isCancelled { throw CancellationError() }
            let remaining = plaintext.count - i
            let nBlocks = min(blocksPerChunk, (remaining + 15) / 16)
            for b in 0..<nBlocks {
                k += 1
                let off = b * 16
                withUnsafeBytes(of: k.littleEndian) { src in for j in 0..<8 { counterBuf[off + j] = src[j] } }
                for j in 8..<16 { counterBuf[off + j] = 0 }
            }
            var moved = 0
            let st = counterBuf.withUnsafeBufferPointer { inp in
                keystream.withUnsafeMutableBufferPointer { outp in
                    CCCryptorUpdate(cryptor, inp.baseAddress, nBlocks * 16,
                                    outp.baseAddress, outp.count, &moved)
                }
            }
            precondition(st == kCCSuccess && moved == nBlocks * 16)
            let chunkBytes = min(remaining, nBlocks * 16)
            for j in 0..<chunkBytes { ct[i + j] = plaintext[i + j] ^ keystream[j] }
            i += chunkBytes
            onBytes?(Int64(chunkBytes))
        }
        return ct
    }

    static func authCode(macKey: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), macKey, macKey.count, ciphertext, ciphertext.count, &mac)
        return Array(mac.prefix(10))
    }

    /// Encrypted data area for one entry: salt(16) ‖ verify(2) ‖ ciphertext ‖ mac(10).
    static func encryptEntry(_ plaintext: Data, password: [UInt8], salt: [UInt8],
                             onBytes: (@Sendable (Int64) -> Void)? = nil) throws -> Data {
        let (aesKey, macKey, verify) = deriveKeys(password: password, salt: salt)
        let ct = try ctrEncrypt(Array(plaintext), key: aesKey, onBytes: onBytes)
        let mac = authCode(macKey: macKey, ciphertext: ct)
        var out = Data()
        out.append(contentsOf: salt); out.append(contentsOf: verify)
        out.append(contentsOf: ct);   out.append(contentsOf: mac)
        return out
    }

    static func encryptEntry(_ plaintext: Data, password: [UInt8],
                             onBytes: (@Sendable (Int64) -> Void)? = nil) throws -> Data {
        var salt = [UInt8](repeating: 0, count: 16)
        precondition(SecRandomCopyBytes(kSecRandomDefault, 16, &salt) == errSecSuccess,
                     "CSPRNG failure generating AES-zip salt")
        return try encryptEntry(plaintext, password: password, salt: salt, onBytes: onBytes)
    }
}

enum AesZipWriter {
    static func write(entries: [(name: String, data: Data)], password: String, to url: URL,
                      onBytes: (@Sendable (Int64) -> Void)? = nil) throws {
        guard entries.count <= 0xFFFF else { throw ZipError.tooManyEntries }
        let pw = Array(password.utf8)
        let plans = try entries.map { e -> ZipEntryPlan in
            if Task.isCancelled { throw CancellationError() }
            guard e.data.count <= Int(UInt32.max) else { throw ZipError.tooLarge }
            let blob = try WinZipAES.encryptEntry(e.data, password: pw, onBytes: onBytes)
            guard blob.count <= Int(UInt32.max) else { throw ZipError.tooLarge }
            return ZipEntryPlan(name: e.name, method: 99, flag: 0x0801, versionNeeded: 51,
                                crc: 0, compressed: UInt32(blob.count),
                                uncompressed: UInt32(e.data.count),
                                extra: WinZipAES.extraField, dataArea: blob)
        }
        try ZipContainer.emit(plans, to: url)
    }
}
