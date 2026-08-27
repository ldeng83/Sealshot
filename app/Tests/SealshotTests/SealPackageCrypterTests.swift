import XCTest
import CryptoKit
@testable import Sealshot

final class SealPackageCrypterTests: XCTestCase {
    let identity = IdentityKey.generate()
    lazy var gen = KeyGeneration.make(publicKey: identity.publicKey)
    var context: SealPackageCryptoContext { SealPackageCryptoContext(
        publicKey: identity.publicKey, generation: gen, identity: identity) }

    func testSealEntriesAddsLockHeaderAndSealsAll() throws {
        let entries = ["manifest.json": Data("{}".utf8), "source.png": Data([1, 2, 3])]
        let (sealed, cek) = try SealPackageCrypter.sealEntries(entries, publicKey: identity.publicKey, generation: gen)
        XCTAssertNotNil(sealed[LockHeader.filename])
        XCTAssertTrue(SealedBlob.isSealed(sealed["manifest.json"]!))
        XCTAssertTrue(SealedBlob.isSealed(sealed["source.png"]!))
        // lock.json itself is plaintext JSON
        XCTAssertNoThrow(try JSONDecoder().decode(LockHeader.self, from: sealed[LockHeader.filename]!))
        // CEK round-trips an entry
        XCTAssertEqual(try SealedBlob.open(sealed["source.png"]!, with: cek), Data([1, 2, 3]))
    }

    func testUnwrapAndOpenRoundTrip() throws {
        let entries = ["manifest.json": Data("{\"v\":5}".utf8)]
        let (sealed, _) = try SealPackageCrypter.sealEntries(entries, publicKey: identity.publicKey, generation: gen)
        let header = try JSONDecoder().decode(LockHeader.self, from: sealed[LockHeader.filename]!)
        let cek = try SealPackageCrypter.unwrapCEK(header, identity: identity)
        XCTAssertEqual(try SealedBlob.open(sealed["manifest.json"]!, with: cek), Data("{\"v\":5}".utf8))
    }

    func testWrongIdentityCannotUnwrap() throws {
        let (sealed, _) = try SealPackageCrypter.sealEntries(["a": Data([9])], publicKey: identity.publicKey, generation: gen)
        let header = try JSONDecoder().decode(LockHeader.self, from: sealed[LockHeader.filename]!)
        XCTAssertThrowsError(try SealPackageCrypter.unwrapCEK(header, identity: .generate()))
    }

    func testSealWithExplicitKeyReusesIt() throws {
        let cek = SymmetricKey(size: .bits256)
        let (sealed, returned) = try SealPackageCrypter.sealEntries(
            ["a": Data([7])], publicKey: identity.publicKey, generation: gen, reusing: cek)
        XCTAssertEqual(returned.withUnsafeBytes { Data($0) }, cek.withUnsafeBytes { Data($0) })
        XCTAssertEqual(try SealedBlob.open(sealed["a"]!, with: cek), Data([7]))
    }

    func testIsLockedDetectsHeaderOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-\(UUID().uuidString).seal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(SealPackageCrypter.isLocked(dir))
        try Data("{}".utf8).write(to: dir.appendingPathComponent(LockHeader.filename))
        XCTAssertTrue(SealPackageCrypter.isLocked(dir))
    }
}
