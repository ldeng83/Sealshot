import Foundation

enum ZipError: Error { case tooLarge, tooManyEntries }

private func appendLE16(_ v: UInt16, to d: inout Data) {
    d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff))
}
private func appendLE32(_ v: UInt32, to d: inout Data) {
    for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) }
}

enum Zip {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
    /// DOS-packed local time/date. Uses Calendar.current (timestamps are cosmetic).
    static func dosDateTime(_ input: Date) -> (time: UInt16, date: UInt16) {
        let comps = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second], from: input)
        let year = max(1980, comps.year ?? 1980)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = (comps.second ?? 0) / 2
        let month = comps.month ?? 1
        let dayOfMonth = comps.day ?? 1
        let packedTime = UInt16((hour << 11) | (minute << 5) | second)
        let packedDate = UInt16(((year - 1980) << 9) | (month << 4) | dayOfMonth)
        return (packedTime, packedDate)
    }
}

struct ZipEntryPlan {
    let name: String
    let method: UInt16
    let flag: UInt16            // general-purpose bit flag (bit 0 = encrypted, bit 11 = UTF-8)
    let versionNeeded: UInt16
    let crc: UInt32
    let compressed: UInt32
    let uncompressed: UInt32
    let extra: [UInt8]
    let dataArea: Data
}

enum ZipContainer {
    static func emit(_ plans: [ZipEntryPlan], to url: URL) throws {
        guard plans.count <= 0xFFFF else { throw ZipError.tooManyEntries }
        let (dtime, ddate) = Zip.dosDateTime(Date())
        var out = Data()
        var central = Data()
        var offsets: [UInt32] = []

        for p in plans {
            let name = Array(p.name.utf8)
            guard name.count <= 0xFFFF, p.extra.count <= 0xFFFF else { throw ZipError.tooLarge }
            guard out.count <= Int(UInt32.max) else { throw ZipError.tooLarge }   // local-header offset must fit (no zip64)
            offsets.append(UInt32(out.count))
            appendLE32(0x04034b50, to: &out)
            appendLE16(p.versionNeeded, to: &out)
            appendLE16(p.flag, to: &out)
            appendLE16(p.method, to: &out)
            appendLE16(dtime, to: &out); appendLE16(ddate, to: &out)
            appendLE32(p.crc, to: &out)
            appendLE32(p.compressed, to: &out)
            appendLE32(p.uncompressed, to: &out)
            appendLE16(UInt16(name.count), to: &out)
            appendLE16(UInt16(p.extra.count), to: &out)
            out.append(contentsOf: name)
            out.append(contentsOf: p.extra)
            out.append(p.dataArea)
        }

        guard out.count <= Int(UInt32.max) else { throw ZipError.tooLarge }
        let centralStart = UInt32(out.count)
        for (i, p) in plans.enumerated() {
            let name = Array(p.name.utf8)
            appendLE32(0x02014b50, to: &central)
            appendLE16(0x031E, to: &central)             // version made by (UNIX 3.0)
            appendLE16(p.versionNeeded, to: &central)
            appendLE16(p.flag, to: &central)
            appendLE16(p.method, to: &central)
            appendLE16(dtime, to: &central); appendLE16(ddate, to: &central)
            appendLE32(p.crc, to: &central)
            appendLE32(p.compressed, to: &central)
            appendLE32(p.uncompressed, to: &central)
            appendLE16(UInt16(name.count), to: &central)
            appendLE16(UInt16(p.extra.count), to: &central)
            appendLE16(0, to: &central)                  // comment length
            appendLE16(0, to: &central)                  // disk number start
            appendLE16(0, to: &central)                  // internal attrs
            appendLE32(0, to: &central)                  // external attrs
            appendLE32(offsets[i], to: &central)
            central.append(contentsOf: name)
            central.append(contentsOf: p.extra)
        }
        guard central.count <= Int(UInt32.max) else { throw ZipError.tooLarge }
        let centralSize = UInt32(central.count)
        out.append(central)

        appendLE32(0x06054b50, to: &out)                 // EOCD
        appendLE16(0, to: &out); appendLE16(0, to: &out)
        appendLE16(UInt16(plans.count), to: &out); appendLE16(UInt16(plans.count), to: &out)
        appendLE32(centralSize, to: &out)
        appendLE32(centralStart, to: &out)
        appendLE16(0, to: &out)

        try out.write(to: url, options: .atomic)
    }
}

enum ZipWriter {
    static func write(entries: [(name: String, data: Data)], to url: URL,
                      onBytes: (@Sendable (Int64) -> Void)? = nil) throws {
        guard entries.count <= 0xFFFF else { throw ZipError.tooManyEntries }
        let plans = try entries.map { e -> ZipEntryPlan in
            if Task.isCancelled { throw CancellationError() }
            guard e.data.count <= Int(UInt32.max) else { throw ZipError.tooLarge }
            onBytes?(Int64(e.data.count))
            return ZipEntryPlan(name: e.name, method: 0, flag: 0x0800, versionNeeded: 20,
                                crc: Zip.crc32(e.data), compressed: UInt32(e.data.count),
                                uncompressed: UInt32(e.data.count), extra: [], dataArea: e.data)
        }
        try ZipContainer.emit(plans, to: url)
    }
}
