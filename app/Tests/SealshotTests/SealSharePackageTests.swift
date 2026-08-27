import XCTest
import CryptoKit
@testable import Sealshot

final class SealSharePackageTests: XCTestCase {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private func imageEntry(_ name: String, _ bytes: String) -> SealSharePackage.EntryInput {
        SealSharePackage.EntryInput(name: name, kind: .image, uti: "public.png",
                                    title: name, tags: ["t"], imageData: Data(bytes.utf8), videoURL: nil)
    }

    func testPassphraseRoundTripSingleImage() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: nil)], expiresAt: nil, note: "n", includesOriginal: false)
        try SealSharePackage.write(entries: [imageEntry("a", "alpha")], options: opts, to: out)

        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")
        XCTAssertEqual(unlocked.manifest.entries.count, 1)
        XCTAssertEqual(unlocked.manifest.note, "n")
        XCTAssertFalse(unlocked.manifest.includesOriginal)
        XCTAssertEqual(try unlocked.imageData(forEntry: "a"), Data("alpha".utf8))
    }

    func testWrongPassphraseThrowsBadPassphrase() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("right-one", hint: nil)], expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [imageEntry("a", "alpha")], options: opts, to: out)
        XCTAssertThrowsError(try SealSharePackage.Reader(url: out).unlock(passphrase: "wrong-one")) {
            XCTAssertEqual($0 as? SealSharePackage.Error, .badPassphrase)
        }
    }

    func testIdentityRoundTripAndWrongKey() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let opts = SealSharePackage.BuildOptions(
            recipients: [.identity(id.publicKey, gen)], expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [imageEntry("a", "alpha")], options: opts, to: out)

        let unlocked = try SealSharePackage.Reader(url: out).unlock(identity: id)
        XCTAssertEqual(try unlocked.imageData(forEntry: "a"), Data("alpha".utf8))

        XCTAssertThrowsError(try SealSharePackage.Reader(url: out).unlock(identity: IdentityKey.generate())) {
            XCTAssertEqual($0 as? SealSharePackage.Error, .noMatchingCapsule)
        }
    }

    func testMultiRecipientSameContent() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("shared-secret", hint: nil), .identity(id.publicKey, gen)],
            expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [imageEntry("a", "alpha"), imageEntry("b", "bravo")], options: opts, to: out)

        let viaPass = try SealSharePackage.Reader(url: out).unlock(passphrase: "shared-secret")
        let viaKey = try SealSharePackage.Reader(url: out).unlock(identity: id)
        XCTAssertEqual(try viaPass.imageData(forEntry: "b"), Data("bravo".utf8))
        XCTAssertEqual(try viaKey.imageData(forEntry: "b"), Data("bravo".utf8))
    }

    func testVideoRoundTrip() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let src = tempURL("mov"); defer { try? FileManager.default.removeItem(at: src) }
        let payload = Data("fake-movie-bytes-0123456789".utf8)
        try payload.write(to: src)
        let entry = SealSharePackage.EntryInput(
            name: "clip", kind: .video, uti: "com.apple.quicktime-movie",
            title: "Clip", tags: [], imageData: nil, videoURL: src)
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("video-secret", hint: nil)], expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [entry], options: opts, to: out)

        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "video-secret")
        let decoded = tempURL("mov"); defer { try? FileManager.default.removeItem(at: decoded) }
        try unlocked.extractVideo(forEntry: "clip", to: decoded)
        XCTAssertEqual(try Data(contentsOf: decoded), payload)
    }

    func testTamperedBodyFailsMAC() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: nil)], expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [imageEntry("a", "alpha")], options: opts, to: out)

        var bytes = try Data(contentsOf: out)
        bytes[bytes.count - 40] ^= 0xFF   // flip a byte inside the body, before the 32-byte tag
        try bytes.write(to: out)

        XCTAssertThrowsError(try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")) {
            XCTAssertEqual($0 as? SealSharePackage.Error, .corrupt)
        }
    }

    func testTamperedTagFailsMAC() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: nil)], expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [imageEntry("a", "alpha")], options: opts, to: out)

        var bytes = try Data(contentsOf: out)
        bytes[bytes.count - 1] ^= 0xFF    // flip a byte inside the 32-byte MAC trailer
        try bytes.write(to: out)

        // Header + framing still parse; the MAC check at unlock catches it.
        XCTAssertThrowsError(try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")) {
            XCTAssertEqual($0 as? SealSharePackage.Error, .corrupt)
        }
    }

    func testExpiredPackageCannotUnlock() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: nil)],
            expiresAt: Date(timeIntervalSince1970: 1000), note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [imageEntry("a", "alpha")], options: opts, to: out)

        let reader = try SealSharePackage.Reader(url: out)   // header still readable
        XCTAssertTrue(reader.isExpired)
        XCTAssertThrowsError(try reader.unlock(passphrase: "open sesame")) {
            XCTAssertEqual($0 as? SealSharePackage.Error, .expired)
        }
    }

    func testNonExpiredPackageStillUnlocks() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: nil)],
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800), note: nil, includesOriginal: false) // year 2100
        try SealSharePackage.write(entries: [imageEntry("a", "alpha")], options: opts, to: out)
        let unlocked = try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")
        XCTAssertEqual(try unlocked.imageData(forEntry: "a"), Data("alpha".utf8))
    }

    func testSwappedMediaSegmentsFailMAC() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: nil)], expiresAt: nil, note: nil, includesOriginal: false)
        // equal-length payloads so swapping the two sealed segments keeps byte lengths consistent
        try SealSharePackage.write(entries: [imageEntry("a", "alpha"), imageEntry("b", "bravo")], options: opts, to: out)

        let reader = try SealSharePackage.Reader(url: out)
        let r1 = reader.segmentTable[1]   // media segment for entry "a"
        let r2 = reader.segmentTable[2]   // media segment for entry "b"
        XCTAssertEqual(r1.length, r2.length, "precondition: equal-length sealed segments")

        var bytes = try Data(contentsOf: out)   // startIndex == 0; segment offsets are absolute
        let s1 = bytes.subdata(in: r1.offset ..< r1.offset + r1.length)
        let s2 = bytes.subdata(in: r2.offset ..< r2.offset + r2.length)
        bytes.replaceSubrange(r1.offset ..< r1.offset + r1.length, with: s2)
        bytes.replaceSubrange(r2.offset ..< r2.offset + r2.length, with: s1)
        try bytes.write(to: out)

        XCTAssertThrowsError(try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")) {
            XCTAssertEqual($0 as? SealSharePackage.Error, .corrupt)
        }
    }

    func testTamperedHeaderFailsMAC() throws {
        let out = tempURL("sealshare"); defer { try? FileManager.default.removeItem(at: out) }
        let opts = SealSharePackage.BuildOptions(
            recipients: [.passphrase("open sesame", hint: nil)],
            expiresAt: Date(timeIntervalSince1970: 2_000_000), note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [imageEntry("a", "alpha")], options: opts, to: out)

        var bytes = try Data(contentsOf: out)
        bytes[10] ^= 0xFF   // flip a byte inside the plaintext header JSON (header starts at offset 9)
        try bytes.write(to: out)

        // Tampering the header is detected either at parse (invalid JSON) or at unlock (MAC) — both → corrupt.
        XCTAssertThrowsError(try SealSharePackage.Reader(url: out).unlock(passphrase: "open sesame")) {
            XCTAssertEqual($0 as? SealSharePackage.Error, .corrupt)
        }
    }

    private func tmpShare() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sealshare")
    }

    func testPlaintextImageRoundTrip() throws {
        let out = tmpShare(); defer { try? FileManager.default.removeItem(at: out) }
        let png = Data((0..<512).map { UInt8($0 & 0xff) })   // opaque bytes; plaintext stores raw
        let entry = SealSharePackage.EntryInput(name: "shot.png", kind: .image, uti: "public.png",
                                                title: "shot", tags: [], imageData: png, videoURL: nil)
        let opts = SealSharePackage.BuildOptions(recipients: [], expiresAt: nil, note: "n", includesOriginal: false)
        try SealSharePackage.write(entries: [entry], options: opts, to: out)

        let reader = try SealSharePackage.Reader(url: out)
        XCTAssertFalse(reader.isEncrypted)
        XCTAssertTrue(reader.capsuleSummaries.isEmpty)
        let unlocked = try reader.unlockPlaintext()
        XCTAssertEqual(try unlocked.imageData(forEntry: "shot.png"), png)   // exact bytes back ⇒ MAC-aware bounds correct
    }

    func testPlaintextVideoRoundTrip() throws {
        let out = tmpShare(); defer { try? FileManager.default.removeItem(at: out) }
        let vurl = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let vbytes = Data((0..<2000).map { UInt8(($0 * 7) & 0xff) })
        try vbytes.write(to: vurl); defer { try? FileManager.default.removeItem(at: vurl) }
        let entry = SealSharePackage.EntryInput(name: "clip.mov", kind: .video, uti: "public.mpeg-4",
                                                title: "clip", tags: [], imageData: nil, videoURL: vurl)
        let opts = SealSharePackage.BuildOptions(recipients: [], expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [entry], options: opts, to: out)

        let extracted = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: extracted) }
        try SealSharePackage.Reader(url: out).unlockPlaintext().extractVideo(forEntry: "clip.mov", to: extracted)
        XCTAssertEqual(try Data(contentsOf: extracted), vbytes)
    }

    func testUnlockPlaintextRejectsEncryptedPackage() throws {
        let out = tmpShare(); defer { try? FileManager.default.removeItem(at: out) }
        let entry = SealSharePackage.EntryInput(name: "a.png", kind: .image, uti: "public.png",
                                                title: "a", tags: [], imageData: Data([1,2,3,4]), videoURL: nil)
        let opts = SealSharePackage.BuildOptions(recipients: [.passphrase("password123", hint: nil)],
                                                 expiresAt: nil, note: nil, includesOriginal: false)
        try SealSharePackage.write(entries: [entry], options: opts, to: out)
        let reader = try SealSharePackage.Reader(url: out)
        XCTAssertTrue(reader.isEncrypted)
        XCTAssertThrowsError(try reader.unlockPlaintext())
        XCTAssertEqual(try reader.unlock(passphrase: "password123").manifest.entries.count, 1)  // encrypted still works
    }

    func testWrite_carriesCollectionDescriptor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("c.sealshare")
        let desc = ShareCollectionDescriptor(id: UUID(), name: "Trip")
        try SealSharePackage.write(
            entries: [.init(name: "a.png", kind: .image, uti: "public.png",
                            title: nil, tags: [], imageData: Data("x".utf8), videoURL: nil)],
            options: .init(recipients: [], expiresAt: nil, note: nil,
                           includesOriginal: false, collection: desc),
            to: pkg)
        let manifest = try SealSharePackage.Reader(url: pkg).unlockPlaintext().manifest
        XCTAssertEqual(manifest.collection, desc)
        XCTAssertEqual(manifest.version, 2)
    }
}
