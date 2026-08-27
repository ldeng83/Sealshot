import XCTest
@testable import Sealshot

final class ShareFramingTests: XCTestCase {
    func testUInt64RoundTrip() {
        var d = Data()
        ShareFraming.appendUInt64LE(0x0102_0304_0506_0708, to: &d)
        XCTAssertEqual(d.count, 8)
        XCTAssertEqual(ShareFraming.readUInt64LE(d, at: 0), 0x0102_0304_0506_0708)
    }

    func testUInt32RoundTrip() {
        var d = Data()
        ShareFraming.appendUInt32LE(0xAABB_CCDD, to: &d)
        XCTAssertEqual(ShareFraming.readUInt32LE(d, at: 0), 0xAABB_CCDD)
    }

    func testReadOutOfBoundsReturnsNil() {
        XCTAssertNil(ShareFraming.readUInt32LE(Data([1, 2, 3]), at: 0))
        XCTAssertNil(ShareFraming.readUInt64LE(Data([1, 2, 3, 4]), at: 0))
        XCTAssertNil(ShareFraming.readUInt32LE(Data([1, 2, 3, 4, 5]), at: 3))   // only 2 bytes from offset 3
        XCTAssertNotNil(ShareFraming.readUInt32LE(Data([1, 2, 3, 4, 5]), at: 1)) // 4 bytes available from offset 1
    }

    func testHugeLengthThrowsTruncated() {
        var body = Data()
        ShareFraming.appendUInt64LE(UInt64.max, to: &body)  // length > Int.max
        body.append(contentsOf: [0, 0])
        XCTAssertThrowsError(try ShareFraming.parseSegmentTable(in: body, start: 0, end: body.count)) { error in
            XCTAssertEqual(error as? ShareFraming.Error, .truncated)
        }
    }

    func testSegmentTableRoundTrip() throws {
        var body = Data()
        let s0 = Data("first".utf8), s1 = Data("second!!".utf8), s2 = Data()
        ShareFraming.appendSegment(s0, to: &body)
        ShareFraming.appendSegment(s1, to: &body)
        ShareFraming.appendSegment(s2, to: &body)

        // Place the body at a non-zero start to confirm absolute offsets.
        let prefix = Data([0xFF, 0xFF])
        let file = prefix + body
        let table = try ShareFraming.parseSegmentTable(in: file, start: prefix.count, end: file.count)
        XCTAssertEqual(table.count, 3)
        XCTAssertEqual(file.subdata(in: table[0].offset..<table[0].offset + table[0].length), s0)
        XCTAssertEqual(file.subdata(in: table[1].offset..<table[1].offset + table[1].length), s1)
        XCTAssertEqual(table[2].length, 0)
    }

    func testTruncatedSegmentThrows() {
        var body = Data()
        ShareFraming.appendUInt64LE(100, to: &body) // claims 100 bytes, none follow
        XCTAssertThrowsError(try ShareFraming.parseSegmentTable(in: body, start: 0, end: body.count))
    }
}
