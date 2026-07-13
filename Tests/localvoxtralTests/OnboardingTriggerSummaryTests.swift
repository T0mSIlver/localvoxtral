import Carbon.HIToolbox
import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class OnboardingTriggerSummaryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "localvoxtral.OnboardingTriggerSummaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        self.defaults = defaults
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = ""
        try await super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, environment: [:])
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

    func testFormatter_optionSpace() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_Space), carbonModifierFlags: UInt32(optionKey))
        XCTAssertEqual(DictationShortcutFormatter.string(for: shortcut), "⌥Space")
    }

    func testFormatter_commandShiftLetter_usesConventionalGlyphOrder() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D), carbonModifierFlags: UInt32(cmdKey | shiftKey))
        XCTAssertEqual(DictationShortcutFormatter.string(for: shortcut), "⇧⌘D")
    }

    func testFormatter_controlOptionLetter() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_A), carbonModifierFlags: UInt32(controlKey | optionKey))
        XCTAssertEqual(DictationShortcutFormatter.string(for: shortcut), "⌃⌥A")
    }

    func testFormatter_unknownKeyCode_fallsBack() {
        let shortcut = DictationShortcut(keyCode: 9999, carbonModifierFlags: UInt32(cmdKey))
        XCTAssertEqual(DictationShortcutFormatter.string(for: shortcut), "⌘Key 9999")
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
