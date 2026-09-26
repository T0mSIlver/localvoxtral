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

    /// The regression, in the shape the field bug actually had: the title is
    /// turned back on with the view already installed and the window already
    /// key, and NOTHING else happens afterwards — no further event, no window
    /// update. A correction that waits for the next update pass leaves the
    /// title on screen for as long as the app stays idle, which is what the
    /// owner saw. So the title has to be down again by the time the write
    /// returns.
    func testTitleTurnedBackOnIsHiddenAgainWithoutWaitingForAnEvent() {
        let window = makeWindow()
        window.title = "localvoxtral Settings"
        let chrome = SettingsWindowChromeView()
        window.contentView?.addSubview(chrome)
        XCTAssertEqual(window.titleVisibility, .hidden, "installing the view applies the chrome")
        XCTAssertEqual(window.title, SettingsWindowChromeView.windowTitle)
        XCTAssertFalse(window.title.isEmpty)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))

        window.titleVisibility = .visible

        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    /// The update pass repairs each property that KVO does not observe.
    /// Each case starts with a fresh window so another stale field cannot
    /// cause the correction to pass for the wrong reason.
    func testWindowUpdateRestoresEachStaleChromeProperty() {
        func check(
            _ property: String,
            corrupt: (NSWindow) -> Void,
            isRestored: (NSWindow) -> Bool
        ) {
            let window = makeWindow()
            let chrome = SettingsWindowChromeView()
            window.contentView?.addSubview(chrome)

            XCTAssertTrue(isRestored(window), "\(property) starts correct")
            corrupt(window)
            XCTAssertFalse(isRestored(window), "\(property) was changed")
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            XCTAssertTrue(isRestored(window), "\(property) is restored on update")
            XCTAssertEqual(window.titleVisibility, .hidden)
        }

        check("title", corrupt: { $0.title = "localvoxtral Settings" },
              isRestored: { $0.title == SettingsWindowChromeView.windowTitle })
        check("transparency", corrupt: { $0.titlebarAppearsTransparent = false },
              isRestored: { $0.titlebarAppearsTransparent })
        check("separator", corrupt: { $0.titlebarSeparatorStyle = .line },
              isRestored: { $0.titlebarSeparatorStyle == .none })
        check("full-size content", corrupt: { $0.styleMask.remove(.fullSizeContentView) },
              isRestored: { $0.styleMask.contains(.fullSizeContentView) })
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
