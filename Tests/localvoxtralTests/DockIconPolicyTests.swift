import AppKit
import XCTest
@testable import localvoxtral

@MainActor
final class DockIconPolicyTests: XCTestCase {
    /// Stand-ins for `ObjectIdentifier(window)` — the policy only ever
    /// compares identities, so any two distinct objects do.
    private final class WindowStub {}

    private var applied: [NSApplication.ActivationPolicy] = []
    private var settingsWindow = WindowStub()
    private var onboardingWindow = WindowStub()

    private func makePolicy() -> DockIconPolicy {
        applied = []
        return DockIconPolicy(initialPolicy: .accessory) { [weak self] policy in
            self?.applied.append(policy)
            return true
        }
    }

    private var settingsID: ObjectIdentifier { ObjectIdentifier(settingsWindow) }
    private var onboardingID: ObjectIdentifier { ObjectIdentifier(onboardingWindow) }

    func testStartsAsAccessoryWithoutTouchingTheApplicationPolicy() {
        let policy = makePolicy()

        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertEqual(applied, [])
    }

    /// `DockIconWindowRegistrarView` deregisters from both `willClose` and
    /// view teardown, so the same window can be removed twice.
    func testRemovingAnAlreadyClosedWindowIsANoOp() {
        let policy = makePolicy()

        policy.addWindow(settingsID)
        policy.removeWindow(settingsID)
        policy.removeWindow(settingsID)
        policy.removeWindow(onboardingID)

        XCTAssertEqual(applied, [.regular, .accessory])
    }

    /// The registrar can re-register a window it already holds when SwiftUI
    /// re-runs `viewDidMoveToWindow`; a duplicate must not leave a phantom
    /// entry that keeps the Dock icon alive after the window closes.
    func testReregisteringTheSameWindowLeavesNoPhantomEntry() {
        let policy = makePolicy()

        policy.addWindow(settingsID)
        policy.addWindow(settingsID)
        policy.removeWindow(settingsID)

        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    /// A refused `setActivationPolicy` must not be recorded as applied: the
    /// process is still `.accessory`, so the next window has to try again
    /// rather than skip the call as redundant.
    func testARefusedPolicyChangeIsRetriedByTheNextWindow() {
        var accept = false
        var attempts: [NSApplication.ActivationPolicy] = []
        let policy = DockIconPolicy(initialPolicy: .accessory) { requested in
            attempts.append(requested)
            return accept
        }

        policy.addWindow(settingsID)
        XCTAssertEqual(attempts, [.regular])
        XCTAssertEqual(policy.currentPolicy, .accessory, "the process refused, so nothing changed")

        accept = true
        policy.addWindow(onboardingID)

        XCTAssertEqual(attempts, [.regular, .regular], "the second window tries again")
        XCTAssertEqual(policy.currentPolicy, .regular)
    }
}
