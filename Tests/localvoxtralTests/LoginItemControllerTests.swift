import Foundation
import XCTest

@testable import localvoxtral

/// "Open localvoxtral at login" (#449). Never the real `SMAppService`: a test
/// that registered it would add the test runner to the developer's own login
/// items.
@MainActor
final class LoginItemControllerTests: XCTestCase {
    private final class FakeRegistrar: LoginItemRegistering {
        var state: LoginItemState
        /// What `register()` lands on when it does not throw — the system, not
        /// the caller, decides whether approval is still needed.
        var stateAfterRegister: LoginItemState = .enabled
        var registerError: Error?
        var unregisterError: Error?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0
        private(set) var openSystemSettingsCount = 0

        init(state: LoginItemState) {
            self.state = state
        }

        func currentState() -> LoginItemState { state }

        func register() throws {
            registerCount += 1
            if let registerError { throw registerError }
            state = stateAfterRegister
        }

        func unregister() throws {
            unregisterCount += 1
            if let unregisterError { throw unregisterError }
            state = .disabled
        }

        func openSystemSettings() {
            openSystemSettingsCount += 1
        }
    }

    private struct RefusedByTheSystem: Error {}

    func testTurningItOnRegistersTheLoginItem() {
        let registrar = FakeRegistrar(state: .disabled)
        let controller = LoginItemController(registrar: registrar)
        XCTAssertFalse(controller.isOn)

        controller.setOn(true)

        XCTAssertEqual(registrar.registerCount, 1)
        XCTAssertTrue(controller.isOn)
        XCTAssertNil(controller.statusMessage)
    }

    func testTurningItOffUnregistersTheLoginItem() {
        let registrar = FakeRegistrar(state: .enabled)
        let controller = LoginItemController(registrar: registrar)
        XCTAssertTrue(controller.isOn)

        controller.setOn(false)

        XCTAssertEqual(registrar.unregisterCount, 1)
        XCTAssertFalse(controller.isOn)
        XCTAssertNil(controller.statusMessage)
    }

    /// The switch follows the system's answer, not the caller's request: a
    /// `register()` that returns without throwing can still need approval.
    func testAwaitingApprovalReadsAsOnAndSaysSo() {
        let registrar = FakeRegistrar(state: .disabled)
        registrar.stateAfterRegister = .requiresApproval
        let controller = LoginItemController(registrar: registrar)

        controller.setOn(true)

        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(controller.statusMessage, "Needs your approval in System Settings.")
        // The one state with somewhere to send the user — and the only one
        // whose row offers the button that takes them there.
        XCTAssertTrue(controller.needsApproval)
        controller.openSystemSettings()
        XCTAssertEqual(registrar.openSystemSettingsCount, 1)
    }

    func testARefusedRegistrationLeavesTheSwitchOffAndExplains() {
        let registrar = FakeRegistrar(state: .disabled)
        registrar.registerError = RefusedByTheSystem()
        let controller = LoginItemController(registrar: registrar)

        controller.setOn(true)

        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(
            controller.statusMessage, "Couldn't add localvoxtral to your login items.")
    }

    func testARefusedRemovalLeavesTheSwitchOnAndExplains() {
        let registrar = FakeRegistrar(state: .enabled)
        registrar.unregisterError = RefusedByTheSystem()
        let controller = LoginItemController(registrar: registrar)

        controller.setOn(false)

        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(
            controller.statusMessage, "Couldn't remove localvoxtral from your login items.")
    }

    /// System Settings can turn the login item off while the app is running,
    /// so the pane re-reads the system rather than trusting what it last saw.
    func testRefreshTakesTheSystemsAnswerAndClearsAStaleFailure() {
        let registrar = FakeRegistrar(state: .enabled)
        registrar.unregisterError = RefusedByTheSystem()
        let controller = LoginItemController(registrar: registrar)
        controller.setOn(false)
        XCTAssertNotNil(controller.statusMessage)

        registrar.state = .disabled
        controller.refresh()

        XCTAssertFalse(controller.isOn)
        XCTAssertNil(controller.statusMessage)
    }

    /// An unbundled build (`swift run`) has no login item to register. The row
    /// says why instead of offering a switch that cannot work.
    func testAnUnavailableLoginItemDisablesTheRow() {
        let controller = LoginItemController(registrar: FakeRegistrar(state: .unavailable))

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(controller.needsApproval)
        XCTAssertEqual(controller.statusMessage, "Only an installed copy can do this.")
    }
}
