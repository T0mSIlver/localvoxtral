import Carbon.HIToolbox
import XCTest
@testable import localvoxtral

final class ShortcutValidationTests: XCTestCase {
    func testValidation_rejectsReservedShortcuts() {
        let reservedShortcuts = [
            DictationShortcut(
                keyCode: UInt32(kVK_Space),
                carbonModifierFlags: UInt32(cmdKey)
            ),
            DictationShortcut(
                keyCode: UInt32(kVK_Space),
                carbonModifierFlags: UInt32(cmdKey | optionKey)
            ),
            DictationShortcut(
                keyCode: UInt32(kVK_Tab),
                carbonModifierFlags: UInt32(cmdKey)
            ),
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_Q),
                carbonModifierFlags: UInt32(cmdKey)
            ),
            DictationShortcut(
                keyCode: UInt32(kVK_ANSI_W),
                carbonModifierFlags: UInt32(cmdKey)
            ),
        ]

        for shortcut in reservedShortcuts {
            XCTAssertNotNil(DictationShortcutValidation.validationErrorMessage(for: shortcut))
        }
    }

    func testValidation_allowsValidModifiedShortcut() {
        let shortcut = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifierFlags: UInt32(cmdKey | shiftKey)
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
