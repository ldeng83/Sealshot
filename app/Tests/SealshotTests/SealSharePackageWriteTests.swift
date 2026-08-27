import XCTest
import CryptoKit
@testable import Sealshot

final class SealSharePackageWriteTests: XCTestCase {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    func testWriteProducesParseableHeaderWithCapsuleSummaries() throws {
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let out = tempURL("sealshare")
        defer { try? FileManager.default.removeItem(at: out) }

        let entry = SealSharePackage.EntryInput(
            name: "shot", kind: .image, uti: "public.png",
            title: "Shot", tags: ["a"], imageData: Data("png-bytes".utf8), videoURL: nil)
        let options = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: "phrase"),
                         .identity(id.publicKey, gen)],
            expiresAt: nil, note: "note", includesOriginal: false)

        try SealSharePackage.write(entries: [entry], options: options, to: out)

        let reader = try SealSharePackage.Reader(url: out)
        XCTAssertEqual(reader.capsuleSummaries.count, 2)
        XCTAssertTrue(reader.capsuleSummaries.contains { $0.kind == .passphrase && $0.hint == "phrase" })
        XCTAssertTrue(reader.capsuleSummaries.contains {
            $0.kind == .identity && $0.generationID == gen.id })
        XCTAssertFalse(reader.isExpired)
    }

    func testFutureVersionRejected() throws {
        let bad = tempURL("sealshare")
        defer { try? FileManager.default.removeItem(at: bad) }
        // Valid magic, version byte 99, minimal but well-formed-enough tail.
        var bytes = Data("SLSP".utf8)
        bytes.append(99)
        bytes.append(contentsOf: [0, 0, 0, 0])          // headerLen = 0
        bytes.append(Data(repeating: 0, count: 32))     // 32-byte mac trailer placeholder
        try bytes.write(to: bad)
        XCTAssertThrowsError(try SealSharePackage.Reader(url: bad)) { error in
            XCTAssertEqual(error as? SealSharePackage.Error, .unsupportedVersion(99))
        }
    }

    func testMagicAndVersionGuards() throws {
        let bad = tempURL("sealshare")
        defer { try? FileManager.default.removeItem(at: bad) }
        try Data("NOPEnot-a-real-package".utf8).write(to: bad)
        XCTAssertThrowsError(try SealSharePackage.Reader(url: bad)) { error in
            XCTAssertEqual(error as? SealSharePackage.Error, .notSharePackage)
        }
    }

    func testShortPassphraseRejected() {
        let out = tempURL("sealshare")
        let entry = SealSharePackage.EntryInput(
            name: "x", kind: .image, uti: "public.png", title: nil, tags: [],
            imageData: Data([1]), videoURL: nil)
        let options = SealSharePackage.BuildOptions(
            recipients: [.passphrase("short", hint: nil)], expiresAt: nil, note: nil, includesOriginal: false)
        XCTAssertThrowsError(try SealSharePackage.write(entries: [entry], options: options, to: out)) { error in
            XCTAssertEqual(error as? SealSharePackage.Error, .passphraseTooShort)
        }
    }

    func testNoRecipientsProducesPlaintextPackage() throws {
        // Empty recipients → plaintext (unencrypted) package; no longer an error.
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let entry = SealSharePackage.EntryInput(
            name: "x", kind: .image, uti: "public.png", title: nil, tags: [],
            imageData: Data([1]), videoURL: nil)
        let options = SealSharePackage.BuildOptions(
            recipients: [], expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [entry], options: options, to: out)
        let reader = try SealSharePackage.Reader(url: out)
        XCTAssertFalse(reader.isEncrypted)
    }

    func testMissingImageDataRejected() {
        let out = tempURL("sealshare")
        let entry = SealSharePackage.EntryInput(
            name: "x", kind: .image, uti: "public.png", title: nil, tags: [],
            imageData: nil, videoURL: nil)
        let options = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: nil)], expiresAt: nil, note: nil, includesOriginal: false)
        XCTAssertThrowsError(try SealSharePackage.write(entries: [entry], options: options, to: out)) { error in
            XCTAssertEqual(error as? SealSharePackage.Error, .missingEntryData)
        }
    }
}
