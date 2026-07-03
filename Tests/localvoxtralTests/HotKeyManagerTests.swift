import Carbon.HIToolbox
import XCTest
@testable import localvoxtral

@MainActor
final class HotKeyManagerTests: XCTestCase {
    func testDualRegistrationReportsLivePasteFailureAfterOverlaySucceeds() {
        resetDebugHotKeyState()
        defer { resetDebugHotKeyState() }

        let manager = HotKeyManager()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .livePaste, status: OSStatus(eventHotKeyExistsErr))

        let result = manager.registerDual(
            overlay: DictationShortcut(
                keyCode: UInt32(kVK_ANSI_D),
                carbonModifierFlags: UInt32(controlKey | optionKey)
            ),
            livePaste: DictationShortcut(
                keyCode: UInt32(kVK_ANSI_F),
                carbonModifierFlags: UInt32(controlKey | optionKey)
            )
        )

        guard case .failure(.livePasteShortcutUnavailable) = result else {
            return XCTFail("Expected livePasteShortcutUnavailable, got \(result)")
        }
    }

    func testModifierOnlyStartupFailurePreservesPreviousRegistration() {
        resetDebugHotKeyState()
        defer { resetDebugHotKeyState() }

        let manager = HotKeyManager()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)

        let initialResult = manager.register(shortcut: DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifierFlags: UInt32(controlKey | optionKey)
        ))
        guard case .success = initialResult else {
            return XCTFail("Expected initial registration success, got \(initialResult)")
        }
        XCTAssertEqual(manager.debugCurrentRegistrationKind, .single)
        let unregisterCountAfterInitialRegistration = HotKeyManager.debugUnregisterCallCount

        ModifierOnlyHotKeyManager.forcedStartOutcome = .monitorInstallationFailed

        let modifierResult = manager.registerModifierOnly(.fn)

        guard case .failure(.modifierOnlyHotKeyUnavailable) = modifierResult else {
            return XCTFail("Expected modifierOnlyHotKeyUnavailable, got \(modifierResult)")
        }
        XCTAssertEqual(HotKeyManager.debugUnregisterCallCount, unregisterCountAfterInitialRegistration)
        XCTAssertEqual(manager.debugCurrentRegistrationKind, .single)
    }

    private func resetDebugHotKeyState() {
        HotKeyManager.debugResetOverridesForTesting()
        ModifierOnlyHotKeyManager.resetDebugState()
    }
}
