import Foundation

enum ShareFraming {
    enum Error: Swift.Error, Equatable { case truncated }

    struct SegmentRange: Equatable {
        var offset: Int   // absolute byte offset of the payload within the file/data
        var length: Int
    }

    static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    static func appendUInt64LE(_ value: UInt64, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    /// - Note: `data` must be a full buffer with `startIndex == 0`; `offset` is a 0-based absolute byte position.
    static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        let base = data.startIndex + offset
        guard offset >= 0, base + 4 <= data.endIndex else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[base + i]) << (8 * i) }
        return v
    }

    /// - Note: `data` must be a full buffer with `startIndex == 0`; `offset` is a 0-based absolute byte position.
    static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64? {
        let base = data.startIndex + offset
        guard offset >= 0, base + 8 <= data.endIndex else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[base + i]) << (8 * i) }
        return v
    }

    static func appendSegment(_ segment: Data, to body: inout Data) {
        appendUInt64LE(UInt64(segment.count), to: &body)
        body.append(segment)
    }

    /// Walk length-prefixed segments in `data[start..<end]`.
    /// - Important: `data` must be a full buffer with `startIndex == 0`; `start`, `end`,
    ///   and the returned `SegmentRange.offset` are 0-based absolute byte positions.
    ///   Do not pass a non-zero-indexed sub-slice.
    static func parseSegmentTable(in data: Data, start: Int, end: Int) throws -> [SegmentRange] {
        var ranges: [SegmentRange] = []
        var cursor = start
        while cursor < end {
            guard let len = readUInt64LE(data, at: cursor) else { throw Error.truncated }
            guard let length = Int(exactly: len) else { throw Error.truncated }
            let payloadStart = cursor + 8
            let payloadEnd = payloadStart + length
            guard payloadEnd <= end else { throw Error.truncated }
            ranges.append(SegmentRange(offset: payloadStart, length: length))
            cursor = payloadEnd
        }
        return ranges
    }
}
