import XCTest
@testable import Sealshot

final class WinZipAESTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            let a = s.index(s.startIndex, offsetBy: i); let b = s.index(a, offsetBy: 2)
            return UInt8(s[a..<b], radix: 16)!
        }
    }

    // RFC 6070 PBKDF2-HMAC-SHA1 vectors
    func testPBKDF2RFC6070() {
        let p = Array("password".utf8), s = Array("salt".utf8)
        XCTAssertEqual(hex(WinZipAES.pbkdf2(password: p, salt: s, iterations: 1, dkLen: 20)),
                       "0c60c80f961f0e71f3a9b524af6012062fe037a6")
        XCTAssertEqual(hex(WinZipAES.pbkdf2(password: p, salt: s, iterations: 4096, dkLen: 20)),
                       "4b007901b765489abead49d926f721d065a429c1")
    }

    // FIPS-197 AES-256 ECB single-block vector
    func testAES256ECBKnownAnswer() {
        let key = bytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let pt  = bytes("6bc1bee22e409f96e93d7e117393172a")
        XCTAssertEqual(hex(WinZipAES.aesECB(pt, key: key)), "f3eed1bdb5d2a03c064b5a7e3db181f8")
    }

    func testCounterBlockIsLittleEndianStartingValue() {
        XCTAssertEqual(WinZipAES.counterBlock(1), [1,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0])
        XCTAssertEqual(WinZipAES.counterBlock(258), [2,1,0,0,0,0,0,0, 0,0,0,0,0,0,0,0])
    }

    // RFC 2202 HMAC-SHA1 test case 1, truncated to 10 bytes
    func testAuthCodeHMACSHA1() {
        let key = [UInt8](repeating: 0x0b, count: 20)
        let data = Array("Hi There".utf8)
        XCTAssertEqual(hex(WinZipAES.authCode(macKey: key, ciphertext: data)), "b617318655057264e28b")
    }

    func testEncryptEntrySelfDecryptRoundTrip() throws {
        let pw = Array("a-strong-passcode".utf8)
        let salt = (0..<16).map { UInt8($0) }
        let plain = Data((0..<1000).map { UInt8(($0 * 7) & 0xff) })
        let blob = try WinZipAES.encryptEntry(plain, password: pw, salt: salt)
        XCTAssertEqual(blob.count, 16 + 2 + plain.count + 10)

        // parse + decrypt
        let b = [UInt8](blob)
        XCTAssertEqual(Array(b[0..<16]), salt)
        let (aesKey, macKey, verify) = WinZipAES.deriveKeys(password: pw, salt: salt)
        XCTAssertEqual(Array(b[16..<18]), verify)
        let ct = Array(b[18..<(b.count - 10)])
        XCTAssertEqual(Array(b.suffix(10)), WinZipAES.authCode(macKey: macKey, ciphertext: ct))
        XCTAssertEqual(try WinZipAES.ctrEncrypt(ct, key: aesKey), Array(plain))   // XOR is symmetric

        // wrong password → different verify
        let (_, _, wrongVerify) = WinZipAES.deriveKeys(password: Array("wrong".utf8), salt: salt)
        XCTAssertNotEqual(wrongVerify, verify)
    }

    func testAesZipStructureAndSelfDecrypt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = Data("secret contents that span more than one AES block!!".utf8)
        try AesZipWriter.write(entries: [(name: "secret.txt", data: plain)], password: "open-sesame-123", to: url)

        let f = [UInt8](try Data(contentsOf: url))
        // local header signature + AES markers
        XCTAssertEqual(Array(f[0..<4]), [0x50,0x4b,0x03,0x04])
        let method = UInt16(f[8]) | (UInt16(f[9]) << 8)
        XCTAssertEqual(method, 99)
        let flag = UInt16(f[6]) | (UInt16(f[7]) << 8)
        XCTAssertEqual(flag, 0x0801)   // bit0 = encrypted (required for AES), bit11 = UTF-8
        XCTAssertEqual(Array(f[14..<18]), [0,0,0,0])               // CRC = 0 (AE-2)
        let nameLen = Int(f[26]) | (Int(f[27]) << 8)
        let extraLen = Int(f[28]) | (Int(f[29]) << 8)
        XCTAssertEqual(extraLen, 11)
        let extra = Array(f[(30 + nameLen)..<(30 + nameLen + 11)])
        XCTAssertEqual(extra, WinZipAES.extraField)

        // data area: salt16 ‖ verify2 ‖ ct ‖ mac10
        let dataStart = 30 + nameLen + extraLen
        let compressed = Int(f[18]) | (Int(f[19]) << 8) | (Int(f[20]) << 16) | (Int(f[21]) << 24)
        XCTAssertEqual(compressed, 16 + 2 + plain.count + 10)
        let area = Array(f[dataStart..<(dataStart + compressed)])
        let salt = Array(area[0..<16])
        let (aesKey, macKey, verify) = WinZipAES.deriveKeys(password: Array("open-sesame-123".utf8), salt: salt)
        XCTAssertEqual(Array(area[16..<18]), verify)
        let ct = Array(area[18..<(area.count - 10)])
        XCTAssertEqual(Array(area.suffix(10)), WinZipAES.authCode(macKey: macKey, ciphertext: ct))
        XCTAssertEqual(Data(try WinZipAES.ctrEncrypt(ct, key: aesKey)), plain)
    }

    // Frozen known-answer vector — locks the WinZip-AES crypto end-to-end (salt‖verify‖ct‖mac).
    // The algorithm was validated against 7-Zip (extract round-trip) on 2026-06-20; this freezes
    // the exact bytes so a future counter/KDF/HMAC regression is caught in CI without a 3rd-party tool.
    // Inputs: salt = 0x00…0x0f, password "pw", plaintext "KAT".
    func testEncryptEntryKnownAnswer() throws {
        let salt = (0..<16).map { UInt8($0) }
        let blob = try WinZipAES.encryptEntry(Data("KAT".utf8), password: Array("pw".utf8), salt: salt)
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "000102030405060708090a0b0c0d0e0f05a9cbc43d78c7b2fbc774a17bb4a5")
    }

    func testCtrEncryptCancelThrows() async throws {
        let key = (0..<32).map { UInt8($0) }
        let big = [UInt8](repeating: 7, count: 5_000_000)
        let task = Task { try WinZipAES.ctrEncrypt(big, key: key) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError { /* ok */ }
    }
}
