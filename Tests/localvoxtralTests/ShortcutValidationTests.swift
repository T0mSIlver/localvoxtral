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

    func testValidation_rejectsBareKeyShortcut() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifierFlags: 0
        )

        XCTAssertEqual(
            DictationShortcutValidation.validationErrorMessage(for: shortcut),
            "Shortcut must include at least one modifier key."
        )
    }
}
