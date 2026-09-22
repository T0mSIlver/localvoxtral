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

    func testFirstWindowShowsTheDockIcon() {
        let policy = makePolicy()

        policy.addWindow(settingsID)

        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular])
    }

    func testClosingTheOnlyWindowHidesTheDockIcon() {
        let policy = makePolicy()

        policy.addWindow(settingsID)
        policy.removeWindow(settingsID)

        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    /// Settings opened on top of the onboarding wizard must not re-apply
    /// `.regular`: each application activates the app, so a redundant one
    /// steals focus back from whatever the user switched to.
    func testSecondWindowDoesNotReapplyTheRegularPolicy() {
        let policy = makePolicy()

        policy.addWindow(onboardingID)
        policy.addWindow(settingsID)

        XCTAssertEqual(applied, [.regular])
    }

    func testDockIconSurvivesUntilTheLastWindowCloses() {
        let policy = makePolicy()

        policy.addWindow(onboardingID)
        policy.addWindow(settingsID)
        policy.removeWindow(onboardingID)

        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular])

        policy.removeWindow(settingsID)

        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    /// `DockIconWindowRegistrarView` deregisters from both `willClose` and
    /// view teardown, so the same window can be removed twice.
    /// The Dock icon — and the main menu that comes with it — has to be up
    /// BEFORE the window is asked for, or the SwiftUI Settings scene answers
    /// and opens nothing (#449).
    func testAWindowBeingOpenedShowsTheDockIconBeforeItExists() {
        let policy = makePolicy()

        policy.beginWindowOpening()

        XCTAssertEqual(applied, [.regular])
        XCTAssertEqual(policy.currentPolicy, .regular)
    }

    func testAWindowThatOpenedKeepsTheIconWhenTheOpenEnds() {
        let policy = makePolicy()
        policy.beginWindowOpening()
        policy.addWindow(settingsID)

        policy.endWindowOpening()

        XCTAssertEqual(applied, [.regular])
        XCTAssertEqual(policy.currentPolicy, .regular)
    }

    /// An ask that never produced a window must not leave the app with a Dock
    /// tile and nothing to switch to.
    func testAnOpenThatNeverArrivedGivesTheIconBack() {
        let policy = makePolicy()
        policy.beginWindowOpening()

        policy.endWindowOpening()

        XCTAssertEqual(applied, [.regular, .accessory])
    }

    /// Two asks at once (the launch one and a wizard link) are one hold.
    func testOverlappingOpensHoldTheIconUntilTheLastOneEnds() {
        let policy = makePolicy()
        policy.beginWindowOpening()
        policy.beginWindowOpening()

        policy.endWindowOpening()
        XCTAssertEqual(policy.currentPolicy, .regular)

        policy.endWindowOpening()
        XCTAssertEqual(applied, [.regular, .accessory])
    }

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
