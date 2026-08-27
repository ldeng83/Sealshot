import Combine
import ServiceManagement
import XCTest
@testable import Sealshot

/// Scriptable stand-in for the real login-item registration.
private final class FakeLaunchAtLoginService: LaunchAtLoginService {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status = .notRegistered) { self.status = status }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private struct StubError: Error {}

@MainActor
final class LaunchAtLoginModelTests: XCTestCase {

    private func makeModel(_ service: FakeLaunchAtLoginService) -> LaunchAtLoginModel {
        // observesActivation: false — no NSApplication notifications in tests.
        LaunchAtLoginModel(service: service, observesActivation: false)
    }

    func test_initReflectsCurrentStatus() {
        XCTAssertTrue(makeModel(FakeLaunchAtLoginService(status: .enabled)).isEnabled)
        XCTAssertFalse(makeModel(FakeLaunchAtLoginService(status: .notRegistered)).isEnabled)
    }

    func test_setEnabledOnRegistersAndPublishes() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let model = makeModel(service)
        model.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.status, .enabled)
    }

    func test_setEnabledOffUnregistersAndPublishes() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let model = makeModel(service)
        model.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.status, .notRegistered)
    }

    /// The bug this whole change exists for: the published value must follow
    /// the OS, never the request. A failed register leaves the switch OFF.
    func test_failedRegisterLeavesToggleOff() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = StubError()
        let model = makeModel(service)
        model.setEnabled(true)
        XCTAssertFalse(model.isEnabled, "a register that threw must not draw as on")
        XCTAssertEqual(model.status, .notRegistered)
    }

    func test_failedUnregisterLeavesToggleOn() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = StubError()
        let model = makeModel(service)
        model.setEnabled(false)
        XCTAssertTrue(model.isEnabled, "an unregister that threw must not draw as off")
        XCTAssertEqual(model.status, .enabled)
    }

    /// `notFound` (registration points at a replaced bundle — common after an
    /// in-place update) reads as off, and switching off must not call
    /// unregister, which fails with "Operation not permitted".
    func test_notFoundReadsOffAndSkipsUnregister() {
        let service = FakeLaunchAtLoginService(status: .notFound)
        let model = makeModel(service)
        XCTAssertFalse(model.isEnabled)

        model.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 0, "notFound has nothing to unregister")
        XCTAssertFalse(model.isEnabled)
    }

    func test_notFoundCanBeReRegistered() {
        let service = FakeLaunchAtLoginService(status: .notFound)
        let model = makeModel(service)
        model.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(model.isEnabled)
    }

    /// Awaiting the user's approval in System Settings is not "on".
    func test_requiresApprovalReadsOffAndIsFlagged() {
        let model = makeModel(FakeLaunchAtLoginService(status: .requiresApproval))
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(model.requiresApproval)
    }

    /// The drift fix: a status changed outside the app (System Settings, or a
    /// bundle replaced by an update) is picked up by refresh — which is what
    /// runs on app activation.
    func test_refreshPicksUpExternalChange() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let model = makeModel(service)
        XCTAssertTrue(model.isEnabled)

        service.status = .notRegistered      // user removed it in System Settings
        model.refresh()
        XCTAssertFalse(model.isEnabled)

        service.status = .enabled            // and added it back
        model.refresh()
        XCTAssertTrue(model.isEnabled)
    }

    func test_refreshPublishesChange() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let model = makeModel(service)
        var published = 0
        let token = model.objectWillChange.sink { _ in published += 1 }
        defer { token.cancel() }

        model.refresh()
        XCTAssertEqual(published, 0, "an unchanged status must not churn the view")

        service.status = .enabled
        model.refresh()
        XCTAssertGreaterThan(published, 0, "a changed status must invalidate the view")
    }
}
