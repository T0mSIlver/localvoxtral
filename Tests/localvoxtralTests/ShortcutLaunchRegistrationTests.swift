import Carbon.HIToolbox
import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

/// The launch registration reports a dictation key it could not take, the
/// way a settings change does (#1093).
@MainActor
final class ShortcutLaunchRegistrationTests: XCTestCase {
    func testADictationKeyAnotherAppHoldsAtLaunchIsReported() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(
            hotKeyID: .overlay, status: OSStatus(eventHotKeyExistsErr))
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .livePaste, status: noErr)
        defer { HotKeyManager.debugResetOverridesForTesting() }

        let (shortcuts, session) = makeShortcuts()
        shortcuts.settings.setOverlayBufferShortcut(
            DictationShortcut(keyCode: UInt32(kVK_F13), carbonModifierFlags: 0))
        defer { shortcuts.unregister() }

        shortcuts.registerAtLaunch()

        XCTAssertEqual(session.lastError, HotKeyManager.unavailableErrorMessage)
        XCTAssertEqual(session.statusText, HotKeyManager.registrationErrorStatus)
    }

    private func makeShortcuts() -> (ShortcutController, FakeShortcutSession) {
        let defaults = makeTestDefaults()

        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.modifierOnlyHotKeyEnabled = false
        // Only the dictation slots register; the action slots would reach
        // real Carbon, whose answer in a test host is not ours to assert.
        settings.setCopyLastDictationShortcut(nil)
        settings.setAnswerAgentShortcut(nil)

        let shortcuts = ShortcutController(settings: settings)
        let session = FakeShortcutSession()
        shortcuts.install(session: session)
        return (shortcuts, session)
    }
}
