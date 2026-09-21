import Carbon.HIToolbox
import XCTest
@testable import localvoxtral

final class ShortcutValidationTests: XCTestCase {
    func testValidation_rejectsReservedShortcuts() {
        let reservedShortcuts: [(shortcut: DictationShortcut, message: String)] = [
            (
                DictationShortcut(
                    keyCode: UInt32(kVK_Space),
                    carbonModifierFlags: UInt32(cmdKey)
                ),
                "Command-Space is reserved by Spotlight."
            ),
            (
                DictationShortcut(
                    keyCode: UInt32(kVK_Tab),
                    carbonModifierFlags: UInt32(cmdKey)
                ),
                "Command-Tab is reserved for app switching."
            ),
            (
                DictationShortcut(
                    keyCode: UInt32(kVK_ANSI_Q),
                    carbonModifierFlags: UInt32(cmdKey)
                ),
                "Command-Q is reserved for quitting apps."
            ),
            (
                DictationShortcut(
                    keyCode: UInt32(kVK_ANSI_W),
                    carbonModifierFlags: UInt32(cmdKey)
                ),
                "Command-W is reserved for closing windows."
            ),
        ]

        for testCase in reservedShortcuts {
            XCTAssertEqual(
                DictationShortcutValidation.validationErrorMessage(for: testCase.shortcut),
                testCase.message
            )
        }
    }

    func testValidation_allowsValidModifiedShortcut() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifierFlags: UInt32(cmdKey | shiftKey)
        )

        XCTAssertNil(DictationShortcutValidation.validationErrorMessage(for: shortcut))
    }

    func testValidation_allowsOptionSpaceShortcut() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_Space),
            carbonModifierFlags: UInt32(optionKey)
        )

        XCTAssertNil(DictationShortcutValidation.validationErrorMessage(for: shortcut))
    }

    func testValidation_rejectsBareTypingKeys() {
        // Letters, digits, punctuation and the editing keys all type or move
        // something; binding one bare would cost the user that key everywhere.
        let bareKeyCodes: [UInt32] = [
            UInt32(kVK_ANSI_D), UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_7),
            UInt32(kVK_ANSI_Period), UInt32(kVK_Space), UInt32(kVK_Return),
            UInt32(kVK_Tab), UInt32(kVK_Delete), UInt32(kVK_Escape),
            UInt32(kVK_LeftArrow),
        ]

        for keyCode in bareKeyCodes {
            let shortcut = DictationShortcut(keyCode: keyCode, carbonModifierFlags: 0)
            XCTAssertEqual(
                DictationShortcutValidation.validationErrorMessage(for: shortcut),
                "Shortcut needs a modifier key. Only function keys work on their own.",
                "bare key code \(keyCode) should be rejected"
            )
        }
    }

    func testValidation_allowsBareFunctionKeys() {
        let functionKeyCodes: [UInt32] = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
            UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
            UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
        ]

        for keyCode in functionKeyCodes {
            let shortcut = DictationShortcut(keyCode: keyCode, carbonModifierFlags: 0)
            XCTAssertNil(
                DictationShortcutValidation.validationErrorMessage(for: shortcut),
                "bare function key code \(keyCode) should be accepted"
            )
            XCTAssertNil(
                DictationShortcutValidation.persistenceErrorMessage(for: shortcut),
                "bare function key code \(keyCode) should survive persistence"
            )
        }
    }

    func testValidation_stripsTheRecorderFunctionKeyBit() {
        // ShortcutRecorder 3.4.0 (our pin, c86ce0f) returns
        // `SRCocoaToCarbonFlags(flags) | NSFunctionKeyMask` from
        // `carbonModifierFlags` for F1-F20, so a real bare F13 keypress
        // reaches the validator carrying 0x800000 rather than 0. What makes
        // it read as "no modifier" is `normalized` masking down to
        // cmd/option/shift/control. Pinned here because widening that mask
        // would reject every bare function key at the recorder while the rest
        // of this suite stayed green.
        let functionKeyBit: UInt32 = 1 << 23

        let bareF13 = DictationShortcut(
            keyCode: UInt32(kVK_F13),
            carbonModifierFlags: functionKeyBit
        ).normalized

        XCTAssertEqual(bareF13.carbonModifierFlags, 0)
        XCTAssertNil(DictationShortcutValidation.validationErrorMessage(for: bareF13))

        let commandF13 = DictationShortcut(
            keyCode: UInt32(kVK_F13),
            carbonModifierFlags: UInt32(cmdKey) | functionKeyBit
        ).normalized

        XCTAssertEqual(commandF13.carbonModifierFlags, UInt32(cmdKey))
        XCTAssertNil(DictationShortcutValidation.validationErrorMessage(for: commandF13))
    }

    func testValidation_allowsModifiedFunctionKey() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_F13),
            carbonModifierFlags: UInt32(cmdKey | optionKey)
        )

        XCTAssertNil(DictationShortcutValidation.validationErrorMessage(for: shortcut))
    }

    func testValidation_rejectsOutOfRangeKeyCodeEvenWithModifier() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(UInt16.max) + 1,
            carbonModifierFlags: UInt32(cmdKey)
        )

        XCTAssertEqual(
            DictationShortcutValidation.validationErrorMessage(for: shortcut),
            "Shortcut key is not supported."
        )
    }

    func testValidation_unsetSentinelStaysInvalid() {
        // The Live Auto-Paste slot stores "not set" as key code 0 with no
        // modifiers. Key code 0 is the letter `A`, so the bare-key rule is
        // what keeps that sentinel from reading back as a real shortcut.
        let shortcut = DictationShortcut(keyCode: 0, carbonModifierFlags: 0)

        XCTAssertNotNil(DictationShortcutValidation.persistenceErrorMessage(for: shortcut))
    }

    // MARK: - Cross-slot conflicts (#391)

    private static let f13 = DictationShortcut(
        keyCode: UInt32(kVK_F13),
        carbonModifierFlags: 0
    )

    func testConflict_rejectsTheSameShortcutInTheOtherSlot() {
        XCTAssertEqual(
            DictationShortcutValidation.conflictErrorMessage(
                for: Self.f13,
                conflictingWith: Self.f13,
                mode: .overlayBuffer
            ),
            "Already used for Overlay Buffer."
        )

        XCTAssertEqual(
            DictationShortcutValidation.conflictErrorMessage(
                for: Self.f13,
                conflictingWith: Self.f13,
                mode: .liveAutoPaste
            ),
            "Already used for Live Auto-Paste."
        )
    }

    func testConflict_allowsTheShortcutWhenTheOtherSlotIsEmpty() {
        XCTAssertNil(
            DictationShortcutValidation.conflictErrorMessage(
                for: Self.f13,
                conflictingWith: nil,
                mode: .overlayBuffer
            )
        )
    }

    func testConflict_allowsADifferentShortcut() {
        let f14 = DictationShortcut(keyCode: UInt32(kVK_F14), carbonModifierFlags: 0)
        let commandF13 = DictationShortcut(
            keyCode: UInt32(kVK_F13),
            carbonModifierFlags: UInt32(cmdKey)
        )

        XCTAssertNil(
            DictationShortcutValidation.conflictErrorMessage(
                for: f14,
                conflictingWith: Self.f13,
                mode: .overlayBuffer
            )
        )
        XCTAssertNil(
            DictationShortcutValidation.conflictErrorMessage(
                for: commandF13,
                conflictingWith: Self.f13,
                mode: .overlayBuffer
            )
        )
    }

    func testConflict_comparesNormalizedShortcuts() {
        // A freshly recorded function key still carries ShortcutRecorder's
        // function-key bit; the stored slot does not. Comparing raw flags
        // would miss the conflict and hand it back to Carbon.
        let recordedF13 = DictationShortcut(
            keyCode: UInt32(kVK_F13),
            carbonModifierFlags: 1 << 23
        )

        XCTAssertEqual(
            DictationShortcutValidation.conflictErrorMessage(
                for: recordedF13,
                conflictingWith: Self.f13,
                mode: .overlayBuffer
            ),
            "Already used for Overlay Buffer."
        )
    }

    @MainActor
    func testRecorderField_namesTheOtherSlotHoldingTheShortcut() {
        XCTAssertEqual(
            ShortcutRecorderField.rejectionMessage(
                for: Self.f13,
                otherSlot: .init(mode: .overlayBuffer, shortcut: Self.f13)
            ),
            "Already used for Overlay Buffer."
        )
    }

    @MainActor
    func testRecorderField_acceptsTheShortcutOnceTheOtherSlotIsCleared() {
        XCTAssertNil(
            ShortcutRecorderField.rejectionMessage(
                for: Self.f13,
                otherSlot: .init(mode: .overlayBuffer, shortcut: nil)
            )
        )
    }

    @MainActor
    func testRecorderField_keyRuleIsReportedBeforeAnyConflict() {
        // A bare letter is refused for what it is, not as a slot clash.
        let bareD = DictationShortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifierFlags: 0)

        XCTAssertEqual(
            ShortcutRecorderField.rejectionMessage(
                for: bareD,
                otherSlot: .init(mode: .overlayBuffer, shortcut: bareD)
            ),
            "Shortcut needs a modifier key. Only function keys work on their own."
        )
    }
}
