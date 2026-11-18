import Carbon.HIToolbox
import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

@MainActor
final class OnboardingTriggerSummaryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = makeTestDefaults()
    }

    override func tearDown() async throws {
        defaults = nil
        try await super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
    }

    /// A store in keyboard-shortcut mode. A fresh install now seeds the
    /// modifier-only gesture on, so the shortcut cases must turn it off to say
    /// which trigger they are exercising rather than leaning on a default.
    private func makeKeyboardShortcutStore() -> SettingsStore {
        let store = makeStore()
        store.modifierOnlyHotKeyEnabled = false
        return store
    }

    // MARK: - DictationShortcutFormatter

    func testFormatter_rendersGlyphsInConventionalOrder_functionKeysAndFallback() {
        let cases: [(keyCode: Int, modifiers: Int, label: String)] = [
            (kVK_Space, optionKey, "⌥Space"),
            (kVK_ANSI_D, cmdKey | shiftKey, "⇧⌘D"),
            (kVK_ANSI_A, controlKey | optionKey, "⌃⌥A"),
            // Bare function keys are labelled F1 through F20.
            (kVK_F1, 0, "F1"), (kVK_F12, 0, "F12"), (kVK_F13, 0, "F13"),
            (kVK_F17, 0, "F17"), (kVK_F20, 0, "F20"),
            (9999, cmdKey, "⌘Key 9999"),
        ]

        for (keyCode, modifiers, label) in cases {
            let shortcut = DictationShortcut(
                keyCode: UInt32(keyCode), carbonModifierFlags: UInt32(modifiers))
            XCTAssertEqual(DictationShortcutFormatter.string(for: shortcut), label, label)
        }
    }

    // MARK: - DictationTriggerSummary

    func testSummary_modifierOnly_describesTapAndHold() {
        let store = makeStore()
        store.modifierOnlyHotKeyEnabled = true
        store.modifierOnlyHotKeyModifier = .fn

        let summary = DictationTriggerSummary.make(settings: store)

        XCTAssertEqual(summary.primary, "Fn / Globe")
        XCTAssertTrue(summary.explanation.contains("Tap"))
        XCTAssertTrue(summary.explanation.contains("hold"))
        XCTAssertTrue(summary.isModifierOnly)
    }

    func testSummary_keyboardShortcuts_showsOverlayShortcut() {
        // Keyboard-shortcut mode: overlay = Option+Space, no live paste.
        let store = makeKeyboardShortcutStore()

        let summary = DictationTriggerSummary.make(settings: store)

        XCTAssertEqual(summary.primary, "⌥Space")
        XCTAssertTrue(summary.explanation.contains("any text field"))
        XCTAssertFalse(summary.isModifierOnly)
    }

    func testSummary_keyboardWithLivePaste_mentionsBoth() {
        let store = makeKeyboardShortcutStore()
        store.setLivePasteShortcut(
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_L), carbonModifierFlags: UInt32(cmdKey | optionKey)))

        let summary = DictationTriggerSummary.make(settings: store)

        XCTAssertEqual(summary.primary, "⌥Space")
        XCTAssertTrue(summary.explanation.contains("⌥⌘L"))
    }

    func testSummary_onlyLivePaste_showsLivePasteShortcut() {
        let store = makeKeyboardShortcutStore()
        store.setOverlayBufferShortcut(nil)
        store.setLivePasteShortcut(
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_J), carbonModifierFlags: UInt32(cmdKey | shiftKey)))

        let summary = DictationTriggerSummary.make(settings: store)

        XCTAssertEqual(summary.primary, "⇧⌘J")
        XCTAssertTrue(summary.explanation.contains("Live Auto-Paste"))
    }

    func testSummary_noShortcut_pointsToMenuBar() {
        let store = makeKeyboardShortcutStore()
        store.setOverlayBufferShortcut(nil)
        // Live paste is unset by default.

        let summary = DictationTriggerSummary.make(settings: store)

        XCTAssertEqual(summary.primary, "Menu bar")
    }
}
