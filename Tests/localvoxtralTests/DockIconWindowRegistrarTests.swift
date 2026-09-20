import AppKit
import XCTest

@testable import localvoxtral

/// The registrar is what turns a window's lifetime into a Dock icon, so these
/// drive real `NSWindow`s rather than the policy's bookkeeping: the failure
/// this pins is a Dock icon left behind after its window is gone, which only
/// the wiring between the two can produce.
@MainActor
final class DockIconWindowRegistrarTests: XCTestCase {
    private var applied: [NSApplication.ActivationPolicy] = []

    /// `isReleasedWhenClosed` defaults to true, which makes `close()` release
    /// a window the test still holds — SIGSEGV, not a failure. The app's own
    /// windows are equally long-lived: `OnboardingWindowController` turns it
    /// off, and SwiftUI owns the Settings window.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makePolicy() -> DockIconPolicy {
        applied = []
        return DockIconPolicy(initialPolicy: .accessory) { [weak self] policy in
            self?.applied.append(policy)
        }
    }

    func testInstallingTheViewInAWindowShowsTheDockIcon() {
        let policy = makePolicy()
        let window = makeWindow()

        window.contentView?.addSubview(DockIconWindowRegistrarView(policy: policy))

        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular])
    }

    /// Closing a SwiftUI scene's window does not reliably tear its content
    /// view down, so the close notification — not view teardown — is what has
    /// to end the registration.
    func testClosingTheWindowHidesTheDockIconWithoutTearingTheViewDown() {
        let policy = makePolicy()
        let window = makeWindow()
        let registrar = DockIconWindowRegistrarView(policy: policy)
        window.contentView?.addSubview(registrar)

        window.close()

        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertEqual(applied, [.regular, .accessory])
        XCTAssertNotNil(registrar.superview, "the view is still installed; only the window closed")
    }

    func testRemovingTheViewFromItsWindowHidesTheDockIcon() {
        let policy = makePolicy()
        let window = makeWindow()
        let registrar = DockIconWindowRegistrarView(policy: policy)
        window.contentView?.addSubview(registrar)

        registrar.removeFromSuperview()

        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    /// A window that closes after the view has already left it must not
    /// deregister a second time — and more to the point, must not deregister
    /// the window the view moved ON to.
    func testAClosedWindowDoesNotDeregisterTheViewsNewWindow() {
        let policy = makePolicy()
        let first = makeWindow()
        let second = makeWindow()
        let registrar = DockIconWindowRegistrarView(policy: policy)

        first.contentView?.addSubview(registrar)
        registrar.removeFromSuperview()
        second.contentView?.addSubview(registrar)
        first.close()

        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular, .accessory, .regular])
    }

    /// Two registered windows keep one Dock icon between them, and it survives
    /// until the second closes — the Settings-on-top-of-onboarding case.
    func testTwoWindowsKeepOneDockIconUntilBothClose() {
        let policy = makePolicy()
        let first = makeWindow()
        let second = makeWindow()
        first.contentView?.addSubview(DockIconWindowRegistrarView(policy: policy))
        second.contentView?.addSubview(DockIconWindowRegistrarView(policy: policy))

        XCTAssertEqual(applied, [.regular], "the second window does not re-apply the policy")

        first.close()
        XCTAssertEqual(policy.currentPolicy, .regular)

        second.close()
        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    /// A minimized window still belongs in the Dock, and a hidden regular app
    /// keeps its tile — so registration follows the window's LIFETIME, not its
    /// `isVisible`.
    func testOrderingTheWindowOutKeepsTheDockIcon() {
        let policy = makePolicy()
        let window = makeWindow()
        window.contentView?.addSubview(DockIconWindowRegistrarView(policy: policy))

        window.orderOut(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular])
    }
}
