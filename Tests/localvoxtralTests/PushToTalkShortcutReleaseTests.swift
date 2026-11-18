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

    /// A modifier hold whose release never came (the trigger switched to the
    /// shortcuts mid-hold, taking the modifier monitor down) left the hold
    /// latched: the next toggle press started a session and its release
    /// stopped it as a "modifier hold release".
    func testAToggleStartOutlivesItsReleaseAfterAHoldLostItsOwn() {
        let (shortcuts, session) = makeShortcuts()
        shortcuts.settings.dictationShortcutMode = .toggle
        let hotKeys = shortcuts.hotKeyManager

        shortcuts.handleModifierOnlyHoldStart()
        XCTAssertTrue(session.isDictating)
        // No release: the popover's Stop ends the session, which drops
        // the start the hold owned, as the session's stop does.
        session.endDictation(reason: "popover stop")
        shortcuts.clearPushToTalkShortcutSessionAttempt()

        hotKeys.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .overlay)
        hotKeys.debugDeliverHotKeyEventForTesting(pressed: false, hotKeyID: .overlay)

        XCTAssertTrue(session.isDictating, "the toggle key's release stopped the session it started")
        XCTAssertEqual(session.stopReasons, ["popover stop"])
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
