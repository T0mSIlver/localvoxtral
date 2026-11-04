import Carbon.HIToolbox
import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

/// An upgrade over what quick capture left in UserDefaults: nothing reads
/// the old keys, they are not rewritten or deleted, the kept settings keep
/// their values, and no removed shortcut registers a hotkey. The data files
/// (`quick-captures.json`, `voice-memos.json`, a learned-term file with
/// Inbox fields) are covered by `testRuntimeServicesOverQuickCaptureLeftovers…`
/// in `DictationViewModelFailFastUXTests` and `RemovedFeatureStoredStateTests`.
@MainActor
final class RemovedFeatureUpgradeTests: XCTestCase {
    private let bothShifts = DictationShortcut(chord: .bothShifts)
    private let optionF13 = DictationShortcut(keyCode: UInt32(kVK_F13), carbonModifierFlags: UInt32(optionKey))

    /// Every key quick capture, voice memos and Jev wrote, with a live-looking
    /// value: the shortcut on, a chord, Jev as the router, memos on.
    static let quickCaptureKeys: [String: Any] = [
        "settings.quick_capture_shortcut_enabled": true,
        "settings.quick_capture_shortcut_key_code": UInt32(kVK_F13),
        "settings.quick_capture_shortcut_carbon_modifiers": UInt32(optionKey),
        "settings.quick_capture_shortcut_chord": ModifierChord.bothShifts.storageValue,
        "settings.quick_capture_jev_enabled": true,
        "settings.quick_capture_router": "jev",
        "settings.voice_memos_enabled": true,
        "settings.quick_capture_project_lines": ["/Users/me/work/payments": "The ledger service."],
        "settings.jev_api_key": "never-stored",
    ]

    private func seed(_ defaults: UserDefaults, _ keys: [String: Any]) {
        for (key, value) in keys { defaults.set(value, forKey: key) }
    }

    func testStoredQuickCaptureKeysAreLeftAloneAndKeptSettingsKeepTheirValues() {
        let defaults = makeTestDefaults()
        let before = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        before.setOverlayBufferShortcut(optionF13)
        before.setCopyLastDictationShortcut(bothShifts)
        before.agentAttentionEnabled = true
        before.llmPolishingEnabled = true
        seed(defaults, Self.quickCaptureKeys)

        let after = SettingsStore(
            defaults: defaults,
            environment: ["TYPESAFE_API_KEY": "from-the-environment"],
            secretStore: InMemorySecretStore())

        XCTAssertEqual(after.overlayBufferShortcut, optionF13)
        XCTAssertEqual(after.copyLastDictationShortcut, bothShifts)
        XCTAssertTrue(after.agentAttentionEnabled)
        XCTAssertTrue(after.llmPolishingEnabled)
        for (key, value) in Self.quickCaptureKeys {
            XCTAssertNotNil(defaults.object(forKey: key), "\(key) is still stored")
            XCTAssertEqual(
                defaults.object(forKey: key) as? NSObject, value as? NSObject, "\(key) was not rewritten")
        }
    }

    /// Quick capture's chord was the same both-Shifts gesture as the kept Copy
    /// last dictation chord: only the kept slot registers, and it fires once.
    func testAQuickCaptureChordOnAKeptSlotsChordRegistersNothingAndTheKeptSlotStillFires() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.modifierOnlyHotKeyEnabled = false
        settings.setCopyLastDictationShortcut(bothShifts)
        settings.setAnswerAgentShortcut(nil)
        seed(defaults, Self.quickCaptureKeys)
        let relaunched = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        relaunched.modifierOnlyHotKeyEnabled = false

        let shortcuts = ShortcutController(settings: relaunched)
        let session = FakeShortcutSession()
        shortcuts.install(session: session)
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .livePaste, status: noErr)
        addTeardownBlock { @MainActor in
            shortcuts.unregister()
            HotKeyManager.debugResetOverridesForTesting()
        }

        shortcuts.registerAtLaunch()

        XCTAssertNil(session.lastError, "no removed shortcut asked for a key")
        let chords = shortcuts.hotKeyManager.chordMonitor
        XCTAssertEqual(Set(chords.chords.keys.map(String.init(describing:))), ["copyLastDictation"])
        chords.debugHandleFlagsChangedForTesting(held: [.rightShift], timestamp: 200.0)
        chords.debugHandleFlagsChangedForTesting(held: [.leftShift, .rightShift], timestamp: 200.03125)
        chords.debugHandleFlagsChangedForTesting(held: [], timestamp: 200.125)
        XCTAssertEqual(session.copyLastDictationCalls, 1)
        XCTAssertEqual(session.answerAgentCalls, 0)
    }

    /// Quick capture's key was the same key as the kept Copy last dictation
    /// key: the kept slot takes it, nothing else asks Carbon for it.
    func testAQuickCaptureKeyOnAKeptSlotsKeyDoesNotCollideWithIt() {
        let defaults = makeTestDefaults()
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.modifierOnlyHotKeyEnabled = false
        settings.setCopyLastDictationShortcut(optionF13)
        settings.setAnswerAgentShortcut(nil)
        var keys = Self.quickCaptureKeys
        keys["settings.quick_capture_shortcut_chord"] = ""
        seed(defaults, keys)
        let relaunched = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        relaunched.modifierOnlyHotKeyEnabled = false

        let shortcuts = ShortcutController(settings: relaunched)
        let session = FakeShortcutSession()
        shortcuts.install(session: session)
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        for kind in [DebugRegistrationKindHotKeyID.overlay, .livePaste, .copyLastDictation] {
            HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: kind, status: noErr)
        }
        addTeardownBlock { @MainActor in
            shortcuts.unregister()
            HotKeyManager.debugResetOverridesForTesting()
        }

        shortcuts.registerAtLaunch()

        XCTAssertNil(session.lastError)
        XCTAssertTrue(shortcuts.hotKeyManager.isCopyLastDictationShortcutRegistered)
        XCTAssertNil(HotKeyManager.debugForcedRegisterStatusesByID[HotKeyManager.ActionHotKey.copyLastDictation.rawValue],
            "the copy slot took the key once")
        XCTAssertEqual(
            HotKeyManager.ActionHotKey.allCases.map(\.rawValue).sorted(), [3, 5],
            "Carbon ID 4 was quick capture's; no slot registers under it")
        shortcuts.hotKeyManager.debugDeliverHotKeyEventForTesting(pressed: true, hotKeyID: .copyLastDictation)
        XCTAssertEqual(session.copyLastDictationCalls, 1)
    }
}
