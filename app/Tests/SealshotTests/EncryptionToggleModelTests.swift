import XCTest
@testable import Sealshot

/// InMemoryIdentityStore variant whose `load()` can be made to return nil —
/// the same shape as the keychain store when the user cancels or fails the
/// Touch ID / password prompt.
private final class GateableIdentityStore: IdentityStore {
    private let backing = InMemoryIdentityStore()
    var denyLoad = false
    func save(_ identity: IdentityKey) throws { try backing.save(identity) }
    func load() async throws -> IdentityKey? {
        denyLoad ? nil : try await backing.load()
    }
    func loadWithoutUserPresence() throws -> IdentityKey? {
        denyLoad ? nil : try backing.loadWithoutUserPresence()
    }
    func hasStoredIdentity() -> Bool { backing.hasStoredIdentity() }
    func delete() throws { try backing.delete() }
}

/// Stub auth gate: approves or denies on command and records the reasons it was
/// asked, so tests can drive the toggle without a real biometric prompt.
@MainActor
private final class StubAuth: LocalAuthenticating {
    var approve: Bool
    private(set) var reasons: [String] = []
    init(approve: Bool) { self.approve = approve }
    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        return approve
    }
}

/// Stub page-level authorization: flips `isAuthorized` on command so tests can
/// model "the page gate already authenticated" vs "no standing authorization".
@MainActor
private final class StubAuthorization: PrivacyAuthorizing {
    var isAuthorized: Bool
    private(set) var didGrant = false
    init(isAuthorized: Bool) { self.isAuthorized = isAuthorized }
    func grant() {
        didGrant = true
        isAuthorized = true
    }
}

@MainActor
final class EncryptionToggleModelTests: XCTestCase {
    var saveFolder: URL!
    var store: InMemoryIdentityStore!
    var session: EncryptionSession!
    private var auth: StubAuth!
    private var authorization: StubAuthorization!
    var model: EncryptionToggleModel!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("toggle-\(UUID().uuidString)", isDirectory: true)
        saveFolder = base.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        store = InMemoryIdentityStore()
        session = EncryptionSession(identityStore: store,
                                    capsuleFolder: base.appendingPathComponent("keys"),
                                    defaults: UserDefaults(suiteName: "tg-\(UUID().uuidString)")!)
        // Default: a standing page authorization is present (the common path,
        // where the page gate already authenticated). The auth gate approves
        // too, so the fallback path is also exercised by tests that clear it.
        auth = StubAuth(approve: true)
        authorization = StubAuthorization(isAuthorized: true)
        model = EncryptionToggleModel(saveFolder: saveFolder, session: session,
                                      identityStore: store, authenticator: auth,
                                      authorization: authorization)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder.deletingLastPathComponent())
    }

    func testInitialPhaseReflectsDisabled() {
        XCTAssertEqual(model.phase, .idle(enabled: false))
    }

    func testEnableRunsAndSurfacesRecoveryCode() async throws {
        await model.enable()
        if case .showingRecoveryCode(let code) = model.phase {
            XCTAssertFalse(code.isEmpty)
        } else {
            XCTFail("expected .showingRecoveryCode, got \(model.phase)")
        }
        XCTAssertTrue(session.isEnabled)
    }

    func testEnableWithoutStandingAuthorization_promptsAndGrantsWindow() async throws {
        // Encryption off → the page is visible without an unlock, so the toggle
        // itself must run the fresh owner check…
        authorization.isAuthorized = false
        await model.enable()
        XCTAssertEqual(auth.reasons.count, 1)
        // …and a success stamps the shared window, exactly like the page-level
        // unlock, so the page's other controls (and its auto-lock) follow.
        XCTAssertTrue(authorization.didGrant)
        if case .showingRecoveryCode = model.phase {} else {
            XCTFail("expected .showingRecoveryCode, got \(model.phase)")
        }
    }

    func testEnableWithStandingAuthorization_doesNotPromptOrRegrant() async throws {
        await model.enable()
        XCTAssertTrue(auth.reasons.isEmpty)
        XCTAssertFalse(authorization.didGrant)
    }

    func testAcknowledgeRecoveryCodeReturnsToIdleEnabled() async throws {
        await model.enable()
        model.acknowledgeRecoveryCode()
        XCTAssertEqual(model.phase, .idle(enabled: true))
    }

    func testDisableRunsAndReturnsToIdleDisabled() async throws {
        await model.enable()
        model.acknowledgeRecoveryCode()
        await model.disable()
        XCTAssertEqual(model.phase, .idle(enabled: false))
        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(model.canResume)
    }

    func testDisableAlwaysTurnsOffEvenWhenIdentityUnavailable() async throws {
        // The old dead-end: identity can't be loaded (locked session + a store
        // that denies load). Always-can-disable turns encryption OFF anyway.
        // Empty library here → nothing to quarantine.
        let gateable = GateableIdentityStore()
        let base = saveFolder.deletingLastPathComponent()
        let session = EncryptionSession(identityStore: gateable,
                                        capsuleFolder: base.appendingPathComponent("keys2"),
                                        defaults: UserDefaults(suiteName: "tg-\(UUID().uuidString)")!)
        let model = EncryptionToggleModel(saveFolder: saveFolder, session: session,
                                          identityStore: gateable,
                                          authenticator: StubAuth(approve: true),
                                          authorization: StubAuthorization(isAuthorized: true))
        await model.enable()
        model.acknowledgeRecoveryCode()
        session.lock()
        gateable.denyLoad = true

        await model.disable()

        // Encryption is OFF even though the identity was unreachable — no dead-end.
        XCTAssertEqual(model.phase, .idle(enabled: false))
        XCTAssertFalse(session.isEnabled)
    }

    func testEnableFailureSurfacesError() async throws {
        // Tamper a package so encryptAll reports migrationIncomplete.
        let pkg = saveFolder.appendingPathComponent("a.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("{\"version\":4}".utf8).write(to: pkg.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(
            at: pkg.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        await model.enable()
        if case .failed = model.phase {} else {
            XCTFail("expected .failed, got \(model.phase)")
        }
        // Flag stays on (engine contract); model offers resume.
        XCTAssertTrue(session.isEnabled)
        XCTAssertTrue(model.canResume)
    }

    func testProgressUpdatesDuringEnable() async throws {
        for i in 0..<3 {
            let pkg = saveFolder.appendingPathComponent("p\(i).seal", isDirectory: true)
            try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
            try Data("{\"version\":4}".utf8).write(to: pkg.appendingPathComponent("manifest.json"))
        }
        await model.enable()
        // After completion, progress reflects the final tally.
        XCTAssertEqual(model.lastProgress?.total, 3)
    }

    // MARK: - Recovery code view / regenerate

    func testViewRecoveryCodeSurfacesTheSameCode() async throws {
        await model.enable()
        guard case .showingRecoveryCode(let shown) = model.phase else {
            return XCTFail("expected .showingRecoveryCode after enable, got \(model.phase)")
        }
        model.acknowledgeRecoveryCode()
        await model.viewRecoveryCode()
        guard case .showingRecoveryCode(let viewed) = model.phase else {
            return XCTFail("expected .showingRecoveryCode after view, got \(model.phase)")
        }
        XCTAssertEqual(viewed, shown)
    }

    func testRegenerateRecoveryCodeSurfacesANewCode() async throws {
        await model.enable()
        guard case .showingRecoveryCode(let original) = model.phase else {
            return XCTFail("expected .showingRecoveryCode after enable, got \(model.phase)")
        }
        model.acknowledgeRecoveryCode()
        await model.regenerateRecoveryCode()
        guard case .showingRecoveryCode(let fresh) = model.phase else {
            return XCTFail("expected .showingRecoveryCode after regenerate, got \(model.phase)")
        }
        XCTAssertNotEqual(fresh, original)
    }

    func testRotateKeySurfacesANewCode() async throws {
        await model.enable()
        guard case .showingRecoveryCode(let original) = model.phase else {
            return XCTFail("expected .showingRecoveryCode after enable, got \(model.phase)")
        }
        model.acknowledgeRecoveryCode()
        await model.rotateKey()
        guard case .showingRecoveryCode(let rotated) = model.phase else {
            return XCTFail("expected .showingRecoveryCode after rotate, got \(model.phase)")
        }
        XCTAssertNotEqual(rotated, original, "rotation issues a fresh recovery code")
        XCTAssertTrue(session.isEnabled, "still enabled after rotation")
    }

    // MARK: - Security boundary

    func testStandingAuthorizationSkipsThePrompt() async throws {
        // The page gate already authenticated (authorization on by default), so
        // a single page-level prompt covers the toggle — no second prompt here.
        await model.enable()
        model.acknowledgeRecoveryCode()
        await model.disable()
        XCTAssertTrue(auth.reasons.isEmpty,
                      "a standing page authorization must not trigger a fresh prompt")
        XCTAssertFalse(session.isEnabled)
    }

    func testWithoutAuthorizationEnableFallsBackToTheAuthGate() async throws {
        // No standing authorization (e.g. a direct/future call site): the model
        // must enforce its own owner check at the boundary.
        authorization.isAuthorized = false
        await model.enable()
        XCTAssertEqual(auth.reasons, ["Authenticate to turn on Enhanced security"])
        XCTAssertTrue(session.isEnabled)
    }

    func testWithoutAuthorizationDeniedEnableDoesNothing() async throws {
        authorization.isAuthorized = false
        auth.approve = false
        await model.enable()
        XCTAssertEqual(model.phase, .idle(enabled: false))
        XCTAssertFalse(session.isEnabled)
        XCTAssertEqual(auth.reasons, ["Authenticate to turn on Enhanced security"])
    }

    func testWithoutAuthorizationDeniedDisableLeavesEncryptionOn() async throws {
        // Turn it on first (authorized), then drop the authorization and deny.
        await model.enable()
        model.acknowledgeRecoveryCode()
        authorization.isAuthorized = false
        auth.approve = false
        await model.disable()
        // Denied auth must not remove protection; toggle snaps back to ON.
        XCTAssertEqual(model.phase, .idle(enabled: true))
        XCTAssertTrue(session.isEnabled)
        XCTAssertEqual(auth.reasons.last, "Authenticate to turn off Enhanced security")
    }

    // MARK: - Launch-lock preference

    /// Re-enabling Enhanced security is a fresh security setup: it must not
    /// silently inherit "don't lock at launch" set months ago under a key that
    /// no longer exists.
    func testEnableResetsTheLaunchLockPreference() async throws {
        let defaults = UserDefaults(suiteName: "tg-launch-\(UUID().uuidString)")!
        let launchLock = LaunchLockPreference(defaults: defaults)
        launchLock.locksAtLaunch = false
        let model = EncryptionToggleModel(saveFolder: saveFolder, session: session,
                                          identityStore: store, authenticator: auth,
                                          authorization: authorization,
                                          launchLock: launchLock)

        await model.enable()

        XCTAssertTrue(launchLock.locksAtLaunch)
    }

    /// A failed enable leaves the user where they were — no silent posture change.
    func testFailedEnableLeavesTheLaunchLockPreferenceAlone() async throws {
        let defaults = UserDefaults(suiteName: "tg-launch-\(UUID().uuidString)")!
        let launchLock = LaunchLockPreference(defaults: defaults)
        launchLock.locksAtLaunch = false
        authorization.isAuthorized = false
        auth.approve = false
        let model = EncryptionToggleModel(saveFolder: saveFolder, session: session,
                                          identityStore: store, authenticator: auth,
                                          authorization: authorization,
                                          launchLock: launchLock)

        await model.enable()

        XCTAssertFalse(launchLock.locksAtLaunch)
    }

    /// The stuck-tabs regression: the model lives as @State in the Privacy
    /// card, which is torn down when the page gate re-locks or the window
    /// closes. Destroyed while `.showingRecoveryCode`, it used to strand
    /// `operationInProgress == true` forever (didSet belonged to the dead
    /// instance; a fresh init doesn't fire didSet) — permanently disabling
    /// the Editor/Library/Settings tab switcher. deinit must clear it.
    func testModelTeardownMidCeremonyClearsOperationInProgress() async throws {
        await model.enable()
        if case .showingRecoveryCode = model.phase {} else {
            return XCTFail("expected recovery ceremony after enable, got \(model.phase)")
        }
        XCTAssertTrue(session.operationInProgress, "ceremony holds the navigation lock")

        model = nil   // view torn down mid-ceremony — the orphaning case
        // deinit hops to the main actor to clear the flag; let it land.
        for _ in 0..<10 where session.operationInProgress {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(session.operationInProgress,
                       "an orphaned ceremony must not leave navigation locked forever")
    }
}
