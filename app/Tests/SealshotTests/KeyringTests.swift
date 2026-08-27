import XCTest
@testable import Sealshot

final class KeyringTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeRecord(retiredAt: Date? = nil) -> GenerationRecord {
        let pub = IdentityKey.generate().publicKey
        return GenerationRecord(generation: .make(publicKey: pub),
                                publicKeyRaw: pub.rawRepresentation, retiredAt: retiredAt)
    }

    func testRoundTrip() throws {
        let r = makeRecord()
        try Keyring.initial(r).write(toFolder: dir)
        let back = try XCTUnwrap(Keyring.read(fromFolder: dir))
        XCTAssertEqual(back.activeGenerationID, r.generation.id)
        XCTAssertEqual(back.active, r)
    }

    func testAppendingMakesActiveAndKeepsPrior() {
        let a = makeRecord(); let b = makeRecord()
        let ring = Keyring.initial(a).appending(b)
        XCTAssertEqual(ring.activeGenerationID, b.generation.id)
        XCTAssertEqual(ring.generations.count, 2)
        XCTAssertEqual(ring.active, b)
        XCTAssertEqual(ring.record(for: a.generation.id), a, "prior generation stays addressable")
    }

    func testAppendingInactiveKeepsActive() {
        let a = makeRecord(); let b = makeRecord()
        let ring = Keyring.initial(a).appending(b, active: false)
        XCTAssertEqual(ring.activeGenerationID, a.generation.id)
        XCTAssertEqual(ring.generations.count, 2)
    }

    func testRetiringStampsButKeepsRecordAndActive() {
        let a = makeRecord(); let b = makeRecord()
        let when = Date(timeIntervalSince1970: 1000)
        let ring = Keyring.initial(a).appending(b).retiring(a.generation.id, at: when)
        XCTAssertEqual(ring.generations.count, 2, "retired record is kept")
        XCTAssertEqual(ring.record(for: a.generation.id)?.retiredAt, when)
        XCTAssertEqual(ring.activeGenerationID, b.generation.id, "retiring does not change active")
    }

    func testReadRejectsWrongVersion() throws {
        var ring = Keyring.initial(makeRecord())
        ring.version = 99
        try ring.write(toFolder: dir)
        XCTAssertNil(Keyring.read(fromFolder: dir))
    }

    func testReadNilWhenMissing() {
        XCTAssertNil(Keyring.read(fromFolder: dir))
    }
}
