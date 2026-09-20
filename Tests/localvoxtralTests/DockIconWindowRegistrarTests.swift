import AppKit
import XCTest

@testable import localvoxtral

/// The registrar is what turns a window being on screen into a Dock icon, so
/// these drive real `NSWindow`s rather than the policy's bookkeeping: a Dock
/// icon left behind after its window is gone — or missing after the window
/// comes back — is a failure only the wiring between the two can produce.
@MainActor
final class DockIconWindowRegistrarTests: XCTestCase {
    private var applied: [NSApplication.ActivationPolicy] = []

    /// `isReleasedWhenClosed` defaults to true, which makes `close()` release a
    /// window the test still holds — SIGSEGV, not a failure. The app's own
    /// windows are equally long-lived: `OnboardingWindowController` turns it
    /// off, and SwiftUI owns the Settings window.
    ///
    /// Ordered front because registration follows the window being on screen,
    /// which is the state a Settings window is in when it matters.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func makePolicy() -> DockIconPolicy {
        applied = []
        return DockIconPolicy(initialPolicy: .accessory) { [weak self] policy in
            self?.applied.append(policy)
        }
    }

    func testInstallingTheViewInAnOnScreenWindowShowsTheDockIcon() {
        let policy = makePolicy()
        let window = makeWindow()

        window.contentView?.addSubview(DockIconWindowRegistrarView(policy: policy))

        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular])
    }

    /// Closing a SwiftUI scene's window does not tear its content view down, so
    /// the close notification — not view teardown — is what has to end the
    /// registration.
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

    /// The regression, in the shape the hand-check found it (the PR #362 build
    /// on macOS 26): opening Settings a SECOND time left the app without a Dock
    /// icon. SwiftUI keeps the scene's window AND its content view across a
    /// close, so `viewDidMoveToWindow` fires once and never again — a
    /// registration driven by view attachment deregisters on the close and has
    /// nothing left to bring it back.
    func testReopeningTheWindowShowsTheDockIconAgain() {
        let policy = makePolicy()
        let window = makeWindow()
        let registrar = DockIconWindowRegistrarView(policy: policy)
        window.contentView?.addSubview(registrar)

        window.close()
        XCTAssertEqual(policy.currentPolicy, .accessory)
        XCTAssertNotNil(registrar.superview, "SwiftUI keeps the content view across a close")

        // AppKit posts this when the window becomes key on a real session;
        // the build host has no window server, so nothing can become key and
        // the notification has to be posted for the observer to see it.
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular, .accessory, .regular])
    }

    /// The backstop for a reopen that puts the window back on screen without
    /// making it key: the next window update pass picks it up.
    func testAWindowBackOnScreenWithoutBecomingKeyIsCaughtOnTheNextUpdate() {
        let policy = makePolicy()
        let window = makeWindow()
        window.contentView?.addSubview(DockIconWindowRegistrarView(policy: policy))
        window.close()
        XCTAssertEqual(policy.currentPolicy, .accessory)

        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        XCTAssertEqual(policy.currentPolicy, .regular)
    }

    /// The observations are per window: a sibling's update must not register
    /// this one.
    func testAnotherWindowsUpdateDoesNotRegisterThisWindow() {
        let policy = makePolicy()
        let window = makeWindow()
        window.contentView?.addSubview(DockIconWindowRegistrarView(policy: policy))
        window.close()

        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: makeWindow())

        XCTAssertEqual(policy.currentPolicy, .accessory)
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

    /// Minimizing is the case `isVisible` alone gets wrong, and AppKit will not
    /// actually miniaturize a window without a window server — `miniaturize`
    /// leaves `isVisible` true and `isMiniaturized` false on the build host, so
    /// a test that called it would pass for the wrong reason. The window
    /// reports the state instead.
    func testAMinimizedWindowKeepsTheDockIcon() {
        final class MiniaturizedWindow: NSWindow {
            override var isVisible: Bool { false }
            override var isMiniaturized: Bool { true }
        }

        let policy = makePolicy()
        let window = MiniaturizedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false

        XCTAssertTrue(DockIconWindowRegistrarView.isOnScreen(window))

        window.contentView?.addSubview(DockIconWindowRegistrarView(policy: policy))

        XCTAssertEqual(policy.currentPolicy, .regular)
        XCTAssertEqual(applied, [.regular])
    }

    func testAClosedWindowIsNotOnScreen() {
        let window = makeWindow()
        XCTAssertTrue(DockIconWindowRegistrarView.isOnScreen(window))

        window.close()

        XCTAssertFalse(DockIconWindowRegistrarView.isOnScreen(window))
    }
}
