import XCTest
import CryptoKit
@testable import Sealshot

/// `requiresPromise` is the cheap probe that lets the drag source pick its
/// writer strategy WITHOUT rendering anything. It must be manifest-only: the
/// whole point is to avoid touching (and decrypting) the payload.
@MainActor
final class CaptureDragRequiresPromiseTests: XCTestCase {
    private let identity = IdentityKey.generate()
    private lazy var generation = KeyGeneration.make(publicKey: identity.publicKey)
    private var encrypted: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: identity.publicKey, generation: generation,
                                 identity: identity)
    }
    private var plain: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: nil, identity: nil)
    }

    private var made: [URL] = []
    override func tearDownWithError() throws {
        made.forEach { try? FileManager.default.removeItem(at: $0) }
        made = []
    }

    private func videoPackage(crypto: SealPackageCryptoContext) throws -> URL {
        let payload = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-in-\(UUID().uuidString).mov")
        try Data((0..<2_000).map { UInt8($0 & 0xff) }).write(to: payload)
        made.append(payload)
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-\(UUID().uuidString).seal")
        made.append(pkg)
        let manifest = SealManifest(
            version: SealManifest.currentVersion, createdISO8601: "t", modifiedISO8601: "t",
            sourceSize: .init(width: 1920, height: 1080), sourceApp: nil,
            captureKind: .screenRecording,
            video: VideoInfo(durationSeconds: 3.0, hasAudio: false))
        try VideoSealPackageIO.write(to: pkg, payloadTempURL: payload,
                                     originalUTI: "com.apple.quicktime-movie",
                                     manifest: manifest, thumbnailPNG: nil, crypto: crypto)
        return pkg
    }

    private func source(_ url: URL, isVideo: Bool) -> CaptureDragPayload.Source {
        CaptureDragPayload.Source(url: url, displayName: "Clip", isVideo: isVideo)
    }

    /// The case that forces a promise: decrypting the payload eagerly could
    /// mean gigabytes, so it has to happen after the drop.
    func testEncryptedVideoRequiresAPromise() throws {
        let pkg = try videoPackage(crypto: encrypted)
        XCTAssertTrue(CaptureDragPayload.requiresPromise(source(pkg, isVideo: true),
                                                         crypto: encrypted))
    }

    /// Plaintext payload: the eager path is an O(1) clone, so no promise needed
    /// — and this is why a plaintext video already drops into apps that refuse
    /// promises.
    func testPlaintextVideoDoesNotRequireAPromise() throws {
        let pkg = try videoPackage(crypto: plain)
        XCTAssertFalse(CaptureDragPayload.requiresPromise(source(pkg, isVideo: true),
                                                          crypto: plain))
    }

    /// Images render to PNG fast enough to stay on the eager path, encrypted or
    /// not — no package read at all.
    func testImageNeverRequiresAPromise() {
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).seal")
        XCTAssertFalse(CaptureDragPayload.requiresPromise(source(pkg, isVideo: false),
                                                          crypto: encrypted))
    }

    /// Legacy non-package files drag as their own URL.
    func testLegacyMovieFileDoesNotRequireAPromise() {
        let mov = FileManager.default.temporaryDirectory
            .appendingPathComponent("old-\(UUID().uuidString).mov")
        XCTAssertFalse(CaptureDragPayload.requiresPromise(source(mov, isVideo: true),
                                                          crypto: encrypted))
    }

    /// Unreadable package → fail to the promise path, which reports its error
    /// through the normal drop machinery instead of silently dragging nothing.
    func testUnreadableVideoPackageFallsBackToAPromise() {
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).seal")
        XCTAssertTrue(CaptureDragPayload.requiresPromise(source(pkg, isVideo: true),
                                                         crypto: encrypted))
    }
}
