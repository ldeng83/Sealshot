import XCTest
import CryptoKit
@testable import Sealshot

final class SealedChunkFileTests: XCTestCase {
    private var dir: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Deterministic byte pattern so slices are easy to assert.
    private func pattern(_ n: Int) -> Data { Data((0..<n).map { UInt8($0 % 251) }) }

    private func makeSealed(_ plaintext: Data, chunkSize: Int = 16,
                            uti: String = "public.mpeg-4", thumbnail: Data? = nil) throws -> URL {
        let plainURL = dir.appendingPathComponent("in-\(UUID().uuidString).bin")
        try plaintext.write(to: plainURL)
        let outURL = dir.appendingPathComponent("out-\(UUID().uuidString).sealrec")
        try SealedChunkFile.encrypt(plaintextURL: plainURL, to: outURL, key: key,
                                    originalUTI: uti, thumbnail: thumbnail, chunkSize: chunkSize)
        return outURL
    }

    func test_header_roundTripsMetadataAndThumbnail() throws {
        let url = try makeSealed(pattern(40), uti: "com.apple.quicktime-movie",
                                 thumbnail: Data("PNGDATA".utf8))
        let reader = try SealedChunkFile.Reader(url: url, key: key)
        XCTAssertEqual(reader.originalLength, 40)
        XCTAssertEqual(reader.originalUTI, "com.apple.quicktime-movie")
        XCTAssertEqual(reader.thumbnail(), Data("PNGDATA".utf8))
    }

    func test_readWholeFile_matchesPlaintext() throws {
        let plain = pattern(40)                       // chunks of 16 → 16,16,8
        let reader = try SealedChunkFile.Reader(url: try makeSealed(plain), key: key)
        XCTAssertEqual(try reader.read(offset: 0, length: 40), plain)
    }

    func test_arbitraryByteRanges_matchSlices() throws {
        let plain = pattern(100)                      // chunkSize 16 → 7 chunks
        let reader = try SealedChunkFile.Reader(url: try makeSealed(plain), key: key)
        let cases: [(Int64, Int)] = [
            (0, 16), (0, 1), (15, 2),      // chunk-aligned, single byte, cross-boundary
            (17, 30), (96, 10), (99, 5),   // mid, tail (clamps), past-end (clamps)
            (32, 0),                       // zero length
        ]
        for (off, len) in cases {
            let expectedEnd = min(Int(off) + len, plain.count)
            let expected = off < 100 && expectedEnd > Int(off)
                ? plain.subdata(in: Int(off)..<expectedEnd) : Data()
            XCTAssertEqual(try reader.read(offset: off, length: len), expected,
                           "range offset=\(off) len=\(len)")
        }
    }

    func test_decryptWhole_restoresPlaintext() throws {
        let plain = pattern(70)
        let sealed = try makeSealed(plain, chunkSize: 16)
        let outURL = dir.appendingPathComponent("restored.bin")
        try SealedChunkFile.decryptWhole(sealed, to: outURL, key: key)
        XCTAssertEqual(try Data(contentsOf: outURL), plain)
    }

    func test_emptyFile_roundTrips() throws {
        let reader = try SealedChunkFile.Reader(url: try makeSealed(Data(), chunkSize: 16), key: key)
        XCTAssertEqual(reader.originalLength, 0)
        XCTAssertEqual(try reader.read(offset: 0, length: 10), Data())
    }

    func test_wrongKey_failsToOpenHeader() throws {
        let url = try makeSealed(pattern(40))
        XCTAssertThrowsError(try SealedChunkFile.Reader(url: url, key: SymmetricKey(size: .bits256)))
    }

    func test_tamperedChunk_throwsOnRead() throws {
        let url = try makeSealed(pattern(40), chunkSize: 16)
        // Flip a byte deep in the file (within the chunk region) and confirm the
        // covering read fails the GCM tag rather than returning bad plaintext.
        var data = try Data(contentsOf: url)
        data[data.count - 5] ^= 0xFF
        try data.write(to: url)
        let reader = try SealedChunkFile.Reader(url: url, key: key)
        XCTAssertThrowsError(try reader.read(offset: 32, length: 8))
    }

    func test_truncatedFile_failsCoveringRead() throws {
        let url = try makeSealed(pattern(40), chunkSize: 16)
        let data = try Data(contentsOf: url)
        try data.dropLast(10).write(to: url)          // chop into the last chunk
        let reader = try SealedChunkFile.Reader(url: url, key: key)
        XCTAssertThrowsError(try reader.read(offset: 32, length: 8))
    }

    func test_notSealed_throws() throws {
        let url = dir.appendingPathComponent("plain.bin")
        try Data("not a sealed file".utf8).write(to: url)
        XCTAssertThrowsError(try SealedChunkFile.Reader(url: url, key: key))
    }

    func testDecryptWholeHonorsCancellation() throws {
        let key = SymmetricKey(size: .bits256)
        let fm = FileManager.default
        let plain = fm.temporaryDirectory.appendingPathComponent("dw-in-\(UUID().uuidString).mov")
        let sealed = fm.temporaryDirectory.appendingPathComponent("dw-sealed-\(UUID().uuidString)")
        let out = fm.temporaryDirectory.appendingPathComponent("dw-out-\(UUID().uuidString).mov")
        defer { for u in [plain, sealed, out] { try? fm.removeItem(at: u) } }

        try Data((0..<10_000).map { UInt8($0 & 0xff) }).write(to: plain)
        try SealedChunkFile.encrypt(plaintextURL: plain, to: sealed, key: key,
                                    originalUTI: "public.mpeg-4")

        XCTAssertThrowsError(
            try SealedChunkFile.decryptWhole(sealed, to: out, key: key, isCancelled: { true })
        ) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }
}
