import Foundation
import XCTest

@testable import localvoxtral

/// Push to talk ends on the release of the key that started it, not on the
/// release of the other dictation shortcut pressed meanwhile (#1630).
@MainActor
final class PushToTalkShortcutReleaseTests: XCTestCase {
    func testTheOtherShortcutsReleaseDoesNotEndAPushToTalkHold() {
        let (shortcuts, session) = makeShortcuts()
        let hotKeys = shortcuts.hotKeyManager

        hotKeys.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .overlay)
        XCTAssertTrue(session.isDictating)

        hotKeys.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .livePaste)
        hotKeys.debugDeliverHotKeyEventForTesting(pressed: false, hotKeyID: .livePaste)
        XCTAssertTrue(session.isDictating, "the live key's release ended the overlay hold")
        XCTAssertEqual(session.stopReasons, [])

        hotKeys.debugDeliverHotKeyEventForTesting(pressed: false, hotKeyID: .overlay)
        XCTAssertFalse(session.isDictating)
        XCTAssertEqual(session.stopReasons, ["push-to-talk release"])
    }

    func testANewHoldAfterTheFirstEndsOnItsOwnRelease() {
        let (shortcuts, session) = makeShortcuts()
        let hotKeys = shortcuts.hotKeyManager

        hotKeys.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .overlay)
        hotKeys.debugDeliverHotKeyEventForTesting(pressed: false, hotKeyID: .overlay)
        hotKeys.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .livePaste)
        XCTAssertTrue(session.isDictating)

        hotKeys.debugDeliverHotKeyEventForTesting(pressed: false, hotKeyID: .livePaste)
        XCTAssertFalse(session.isDictating)
        XCTAssertEqual(session.stopReasons, ["push-to-talk release", "push-to-talk release"])
    }

    private func makeShortcuts() -> (ShortcutController, FakeShortcutSession) {
        let settings = makeSettings()
        settings.modifierOnlyHotKeyEnabled = false
        settings.dictationShortcutMode = .pushToTalk
        let shortcuts = ShortcutController(settings: settings)
        let session = FakeShortcutSession()
        session.startDictationSucceeds = true
        shortcuts.install(session: session)
        addTeardownBlock { @MainActor in shortcuts.unregister() }
        return (shortcuts, session)
    }
}
