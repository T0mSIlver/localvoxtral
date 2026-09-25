import Foundation
import XCTest

@testable import localvoxtral

/// "Open localvoxtral at login" (#449): how the switch reads and what it does
/// with what the registrar reports. The registrar's own contract — the file
/// launchd reads — is `LaunchAgentLoginItemRegistrarTests`.
@MainActor
final class LoginItemControllerTests: XCTestCase {
    private struct RefusedByTheSystem: Error {}

    func testTurningItOnRegistersTheLoginItem() {
        let registrar = FakeLoginItemRegistrar(state: .disabled)
        let controller = LoginItemController(registrar: registrar)
        XCTAssertFalse(controller.isOn)

        controller.setOn(true)

        XCTAssertEqual(registrar.registerCount, 1)
        XCTAssertTrue(controller.isOn)
        XCTAssertNil(controller.statusMessage)
    }

    func testTurningItOffUnregistersTheLoginItem() {
        let registrar = FakeLoginItemRegistrar(state: .enabled)
        let controller = LoginItemController(registrar: registrar)
        XCTAssertTrue(controller.isOn)

        controller.setOn(false)

        XCTAssertEqual(registrar.unregisterCount, 1)
        XCTAssertFalse(controller.isOn)
        XCTAssertNil(controller.statusMessage)
    }

    /// The switch reads what is on disk, not what was asked for: a login item
    /// that names another copy of localvoxtral is on, and says so.
    func testALoginItemForAnotherCopyReadsAsOnAndSaysSo() {
        let controller = LoginItemController(
            registrar: FakeLoginItemRegistrar(state: .enabledForAnotherCopy))

        XCTAssertTrue(controller.isOn)
        XCTAssertTrue(controller.isAvailable)
        XCTAssertEqual(controller.statusMessage, "Set up for another copy of localvoxtral.")
    }

    func testARefusedRegistrationLeavesTheSwitchOffAndExplains() {
        let registrar = FakeLoginItemRegistrar(state: .disabled)
        registrar.registerError = RefusedByTheSystem()
        let controller = LoginItemController(registrar: registrar)

        controller.setOn(true)

        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(
            controller.statusMessage, "Couldn't add localvoxtral to your login items.")
    }

    func testARefusedRemovalLeavesTheSwitchOnAndExplains() {
        let registrar = FakeLoginItemRegistrar(state: .enabled)
        registrar.unregisterError = RefusedByTheSystem()
        let controller = LoginItemController(registrar: registrar)

        controller.setOn(false)

        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(
            controller.statusMessage, "Couldn't remove localvoxtral from your login items.")
    }

    /// The login item can be removed while the app is running, so the pane
    /// re-reads it rather than trusting what it last saw.
    func testRefreshTakesTheSystemsAnswerAndClearsAStaleFailure() {
        let registrar = FakeLoginItemRegistrar(state: .enabled)
        registrar.unregisterError = RefusedByTheSystem()
        let controller = LoginItemController(registrar: registrar)
        controller.setOn(false)
        XCTAssertNotNil(controller.statusMessage)

        registrar.state = .disabled
        controller.refresh()

        XCTAssertFalse(controller.isOn)
        XCTAssertNil(controller.statusMessage)
    }

    /// An unbundled build (`swift run`) has nothing to open at login. The row
    /// says why instead of offering a switch that cannot work.
    func testAnUnavailableLoginItemDisablesTheRow() {
        let controller = LoginItemController(registrar: FakeLoginItemRegistrar(state: .unavailable))

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(controller.statusMessage, "Only an installed copy can do this.")
    }
}
