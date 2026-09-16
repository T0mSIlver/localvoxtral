import AppKit
import XCTest

@testable import localvoxtral

/// The Settings window must never draw its title: the sidebar's gray runs to
/// the window's top edge and a title lands on top of it, next to the traffic
/// lights (owner field report on 0.8.5-nightly.20260916.2, macOS 26.6.2).
///
/// What made that field bug possible is that the chrome was applied only when
/// the view entered a window and when the window became key, and SwiftUI puts
/// `titleVisibility` back AFTER both — so the window whose titlebar is
/// reconfigured behind the app's back is the case these tests pin.
@MainActor
final class SettingsWindowChromeTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
    }

    func testApplyChromeHidesTheTitleAndOpensUpTheTitlebar() {
        let window = makeWindow()
        window.title = "Settings"

        SettingsWindowChromeView.applyChrome(to: window)

        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    }

    /// `scripts/ui-smoke.sh` pins every AX probe to the window named
    /// "Settings", so the fix for a visible title is never an empty title.
    func testApplyChromeLeavesTheWindowTitleAlone() {
        let window = makeWindow()
        window.title = "localvoxtral Settings"

        SettingsWindowChromeView.applyChrome(to: window)

        XCTAssertEqual(window.title, "localvoxtral Settings")
    }

    func testChromeIsStaleOnlyWhenSomethingWasPutBack() {
        let window = makeWindow()
        SettingsWindowChromeView.applyChrome(to: window)
        XCTAssertFalse(SettingsWindowChromeView.chromeIsStale(window))

        window.titleVisibility = .visible
        XCTAssertTrue(SettingsWindowChromeView.chromeIsStale(window))

        SettingsWindowChromeView.applyChrome(to: window)
        window.titlebarAppearsTransparent = false
        XCTAssertTrue(SettingsWindowChromeView.chromeIsStale(window))

        SettingsWindowChromeView.applyChrome(to: window)
        window.styleMask.remove(.fullSizeContentView)
        XCTAssertTrue(SettingsWindowChromeView.chromeIsStale(window))
    }

    /// The regression, in the shape the field bug actually had: the title is
    /// turned back on with the view already installed and the window already
    /// key, and NOTHING else happens afterwards — no further event, no window
    /// update. A correction that waits for the next update pass leaves the
    /// title on screen for as long as the app stays idle, which is what the
    /// owner saw. So the title has to be down again by the time the write
    /// returns.
    func testTitleTurnedBackOnIsHiddenAgainWithoutWaitingForAnEvent() {
        let window = makeWindow()
        let chrome = SettingsWindowChromeView()
        window.contentView?.addSubview(chrome)
        XCTAssertEqual(window.titleVisibility, .hidden, "installing the view applies the chrome")

        window.titleVisibility = .visible

        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    /// The backstop, exercised through a titlebar setting that is NOT the
    /// observed one: a re-assertion that never goes through `titleVisibility`
    /// is caught on the window's next update pass.
    func testTitlebarPutBackOffTheObservedPropertyIsFixedOnTheNextWindowUpdate() {
        let window = makeWindow()
        let chrome = SettingsWindowChromeView()
        window.contentView?.addSubview(chrome)

        window.titlebarAppearsTransparent = false
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    /// The update pass only listens to its own window: a sibling window's
    /// update must not reach into this one.
    func testAnotherWindowsUpdateDoesNotTouchThisWindow() {
        let window = makeWindow()
        let chrome = SettingsWindowChromeView()
        window.contentView?.addSubview(chrome)

        window.titlebarAppearsTransparent = false
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: makeWindow())

        XCTAssertFalse(window.titlebarAppearsTransparent)
    }

    /// Moving the view to a second window stops the first one's observation,
    /// so a retained view cannot keep correcting a window it has left.
    func testMovingToAnotherWindowStopsObservingTheOldOne() {
        let first = makeWindow()
        let second = makeWindow()
        let chrome = SettingsWindowChromeView()
        first.contentView?.addSubview(chrome)
        chrome.removeFromSuperview()
        second.contentView?.addSubview(chrome)

        first.titleVisibility = .visible
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: first)
        XCTAssertEqual(first.titleVisibility, .visible, "the left window is no longer observed")

        second.titleVisibility = .visible
        XCTAssertEqual(second.titleVisibility, .hidden)
    }
}
