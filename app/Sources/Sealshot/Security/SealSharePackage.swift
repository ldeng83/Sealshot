import Foundation
import CryptoKit

enum SealSharePackage {
    static let magic = Data("SLSP".utf8)
    static let version: UInt8 = 1
    static let minPassphraseLength = 8
    static let macInfo = Data("sealshare-mac-v1".utf8)
    private static let headerPrefixLength = 4 + 1 + 4  // magic + version + headerLen
    static let macLength = 32

    enum Error: Swift.Error, Equatable {
        case notSharePackage
        case unsupportedVersion(UInt8)
        case corrupt
        case passphraseTooShort
        case noRecipients
        case missingEntryData
        case noMatchingCapsule
        case badPassphrase
        case expired
    }

    enum Recipient {
        case passphrase(String, hint: String?)
        case identity(IdentityPublicKey, KeyGeneration)
    }

    struct EntryInput {
        var name: String
        var kind: ShareEntryKind
        var uti: String
        var title: String?
        var tags: [String]
        var imageData: Data?
        var videoURL: URL?

        init(name: String, kind: ShareEntryKind, uti: String, title: String?,
             tags: [String], imageData: Data?, videoURL: URL?) {
            self.name = name; self.kind = kind; self.uti = uti; self.title = title
            self.tags = tags; self.imageData = imageData; self.videoURL = videoURL
        }
    }

    struct BuildOptions {
        var recipients: [Recipient]
        var expiresAt: Date?
        var note: String?
        var includesOriginal: Bool
        var collection: ShareCollectionDescriptor?

        init(recipients: [Recipient], expiresAt: Date?, note: String?,
             includesOriginal: Bool, collection: ShareCollectionDescriptor? = nil) {
            self.recipients = recipients; self.expiresAt = expiresAt
            self.note = note; self.includesOriginal = includesOriginal
            self.collection = collection
        }
    }

    static func deriveMACKey(cek: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: cek, info: macInfo, outputByteCount: 32)
    }

    // MARK: Write

    static func write(entries: [EntryInput], options: BuildOptions, to url: URL) throws {
        for case let .passphrase(pw, _) in options.recipients where pw.count < minPassphraseLength {
            throw Error.passphraseTooShort
        }
        let encrypt = !options.recipients.isEmpty
        let cek = SymmetricKey(size: .bits256)   // used only when encrypt == true

        let manifestEntries = entries.enumerated().map { index, e in
            ShareManifestEntry(name: e.name, kind: e.kind, uti: e.uti, title: e.title,
                               tags: e.tags, segmentIndex: index + 1)
        }
        let manifest = ShareManifest(version: 2, note: options.note,
                                     includesOriginal: options.includesOriginal,
                                     entries: manifestEntries, collection: options.collection)
        var body = Data()
        let manifestData = try JSONEncoder().encode(manifest)
        ShareFraming.appendSegment(encrypt ? try SealedBlob.seal(manifestData, with: cek) : manifestData, to: &body)

        for e in entries {
            switch e.kind {
            case .image:
                guard let img = e.imageData else { throw Error.missingEntryData }
                ShareFraming.appendSegment(encrypt ? try SealedBlob.seal(img, with: cek) : img, to: &body)
            case .video:
                guard let videoURL = e.videoURL else { throw Error.missingEntryData }
                if encrypt {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("sealrec")
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try SealedChunkFile.encrypt(plaintextURL: videoURL, to: tmp, key: cek, originalUTI: e.uti)
                    ShareFraming.appendSegment(try Data(contentsOf: tmp), to: &body)
                } else {
                    ShareFraming.appendSegment(try Data(contentsOf: videoURL), to: &body)
                }
            }
        }

        var capsules: [ShareCapsule] = []
        for r in options.recipients {
            switch r {
            case .passphrase(let pw, let hint):
                capsules.append(.passphrase(try ShareCapsuleCrypter.wrap(cek: cek, passphrase: pw, hint: hint)))
            case .identity(let pub, let gen):
                capsules.append(.identity(try ShareCapsuleCrypter.wrap(cek: cek, recipient: pub, generation: gen)))
            }
        }

        let header = ShareHeader(version: 1, createdAt: Date(),
                                 expiresAt: options.expiresAt, capsules: capsules)
        let headerData = try JSONEncoder().encode(header)

        var out = Data()
        out.append(magic)
        out.append(version)
        ShareFraming.appendUInt32LE(UInt32(headerData.count), to: &out)
        out.append(headerData)
        out.append(body)

        if encrypt {
            let macKey = deriveMACKey(cek: cek)
            let tag = HMAC<SHA256>.authenticationCode(for: out, using: macKey)
            out.append(Data(tag))
        }

        try out.write(to: url, options: .atomic)
    }

    // MARK: Reader (header parsing; decryption lives in Task 6 extension)

    final class Reader {
        let fileURL: URL
        let header: ShareHeader
        let segmentTable: [ShareFraming.SegmentRange]
        let fileLength: Int
        private let data: Data

        init(url: URL) throws {
            self.fileURL = url
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            self.data = data
            self.fileLength = data.count
            guard data.count >= headerPrefixLength,
                  data.prefix(magic.count) == magic else { throw Error.notSharePackage }
            let ver = data[data.startIndex + 4]
            guard ver == version else { throw Error.unsupportedVersion(ver) }
            guard let hlen = ShareFraming.readUInt32LE(data, at: 5) else { throw Error.corrupt }

            let headerStart = headerPrefixLength
            let headerEnd = headerStart + Int(hlen)
            guard headerEnd <= data.count else { throw Error.corrupt }
            let headerData = data.subdata(in: (data.startIndex + headerStart)..<(data.startIndex + headerEnd))
            guard let parsed = try? JSONDecoder().decode(ShareHeader.self, from: headerData) else {
                throw Error.corrupt
            }
            self.header = parsed

            // Plaintext packages (no capsules) carry no MAC trailer.
            let trailer = parsed.capsules.isEmpty ? 0 : macLength
            let bodyStart = headerEnd
            let bodyEnd = data.count - trailer
            guard bodyEnd >= bodyStart else { throw Error.corrupt }
            do {
                self.segmentTable = try ShareFraming.parseSegmentTable(
                    in: data, start: data.startIndex + bodyStart, end: data.startIndex + bodyEnd)
            } catch {
                throw Error.corrupt
            }
        }

        var expiresAt: Date? { header.expiresAt }

        var isExpired: Bool {
            guard let exp = header.expiresAt else { return false }
            return exp < Date()
        }

        var isEncrypted: Bool { !header.capsules.isEmpty }

        func unlockPlaintext() throws -> Unlocked {
            if isExpired { throw Error.expired }
            guard header.capsules.isEmpty else { throw Error.noMatchingCapsule }
            guard let manifestRange = segmentTable.first else { throw Error.corrupt }
            let raw = data.subdata(in: (data.startIndex + manifestRange.offset)
                                   ..< (data.startIndex + manifestRange.offset + manifestRange.length))
            guard let manifest = try? JSONDecoder().decode(ShareManifest.self, from: raw) else {
                throw Error.corrupt
            }
            let dummy = SymmetricKey(data: Data(repeating: 0, count: 32))
            return Unlocked(data: data, cek: dummy, manifest: manifest,
                            segmentTable: segmentTable, isEncrypted: false)
        }

        var capsuleSummaries: [ShareCapsuleSummary] {
            header.capsules.map { capsule in
                switch capsule {
                case .passphrase(let p):
                    return ShareCapsuleSummary(kind: .passphrase, generationID: nil, hint: p.hint)
                case .identity(let k):
                    return ShareCapsuleSummary(kind: .identity, generationID: k.generationID, hint: nil)
                case .unknown:
                    return ShareCapsuleSummary(kind: .unknown, generationID: nil, hint: nil)
                }
            }
        }

        func unlock(identity: IdentityKey) throws -> Unlocked {
            if isExpired { throw Error.expired }
            for capsule in header.capsules {
                if case .identity(let keyCapsule) = capsule,
                   let cek = ShareCapsuleCrypter.unwrap(keyCapsule, identity: identity) {
                    return try makeUnlocked(cek: cek)
                }
            }
            throw Error.noMatchingCapsule
        }

        func unlock(passphrase: String) throws -> Unlocked {
            if isExpired { throw Error.expired }
            var sawPassphraseCapsule = false
            for capsule in header.capsules {
                if case .passphrase(let p) = capsule {
                    sawPassphraseCapsule = true
                    if let cek = ShareCapsuleCrypter.unwrap(p, passphrase: passphrase) {
                        return try makeUnlocked(cek: cek)
                    }
                }
            }
            throw sawPassphraseCapsule ? Error.badPassphrase : Error.noMatchingCapsule
        }

        private func makeUnlocked(cek: SymmetricKey) throws -> Unlocked {
            try verifyMAC(cek: cek)
            guard let manifestRange = segmentTable.first else { throw Error.corrupt }
            let sealed = data.subdata(in: (data.startIndex + manifestRange.offset)
                                      ..< (data.startIndex + manifestRange.offset + manifestRange.length))
            guard let manifestData = try? SealedBlob.open(sealed, with: cek),
                  let manifest = try? JSONDecoder().decode(ShareManifest.self, from: manifestData) else {
                throw Error.corrupt
            }
            return Unlocked(data: data, cek: cek, manifest: manifest, segmentTable: segmentTable)
        }

        private func verifyMAC(cek: SymmetricKey) throws {
            guard data.count >= SealSharePackage.macLength else { throw Error.corrupt }
            let macStart = data.count - SealSharePackage.macLength
            let signed = data.subdata(in: data.startIndex ..< (data.startIndex + macStart))
            let tag = data.subdata(in: (data.startIndex + macStart) ..< data.endIndex)
            let macKey = SealSharePackage.deriveMACKey(cek: cek)
            guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: signed, using: macKey) else {
                throw Error.corrupt
            }
        }
    }

    final class Unlocked {
        private let data: Data
        private let cek: SymmetricKey
        let manifest: ShareManifest
        private let segmentTable: [ShareFraming.SegmentRange]
        private let isEncrypted: Bool

        init(data: Data, cek: SymmetricKey, manifest: ShareManifest,
             segmentTable: [ShareFraming.SegmentRange], isEncrypted: Bool = true) {
            self.data = data; self.cek = cek
            self.manifest = manifest; self.segmentTable = segmentTable
            self.isEncrypted = isEncrypted
        }

        private func segment(forEntry name: String) throws -> (ShareManifestEntry, ShareFraming.SegmentRange) {
            guard let entry = manifest.entries.first(where: { $0.name == name }),
                  entry.segmentIndex < segmentTable.count else { throw Error.corrupt }
            return (entry, segmentTable[entry.segmentIndex])
        }

        private func sealedBytes(_ range: ShareFraming.SegmentRange) -> Data {
            let start = data.startIndex + range.offset
            return data.subdata(in: start ..< (start + range.length))
        }

        func imageData(forEntry name: String) throws -> Data {
            let (entry, range) = try segment(forEntry: name)
            guard entry.kind == .image else { throw Error.corrupt }
            let bytes = sealedBytes(range)
            return isEncrypted ? try SealedBlob.open(bytes, with: cek) : bytes
        }

        func extractVideo(forEntry name: String, to url: URL) throws {
            let (entry, range) = try segment(forEntry: name)
            guard entry.kind == .video else { throw Error.corrupt }
            if isEncrypted {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("sealrec")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try sealedBytes(range).write(to: tmp, options: .atomic)
                try SealedChunkFile.decryptWhole(tmp, to: url, key: cek)
            } else {
                try sealedBytes(range).write(to: url, options: .atomic)
            }
        }
    }
}
