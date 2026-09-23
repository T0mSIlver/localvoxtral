import Carbon.HIToolbox

struct DictationShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifierFlags: UInt32

    var normalized: DictationShortcut {
        DictationShortcut(
            keyCode: keyCode,
            carbonModifierFlags: DictationShortcutValidation.normalizedModifierFlags(
                carbonModifierFlags)
        )
    }
}

enum DictationShortcutValidation {
    static let allowedModifierFlagsMask = UInt32(cmdKey | optionKey | shiftKey | controlKey)

    static func normalizedModifierFlags(_ flags: UInt32) -> UInt32 {
        flags & allowedModifierFlagsMask
    }

    /// The one key class accepted with no modifier at all. The bare-key rule
    /// exists so nobody binds the letter `a` and loses the ability to type it;
    /// a function key has no typing role to swallow, and F13-F20 in particular
    /// are dedicated keys whose only plausible use is a trigger like this one.
    /// Letters, digits, punctuation, Space and Return still need a modifier.
    ///
    /// F1-F12 are included (#377 asks for the whole range) but only fire on a
    /// keyboard that sends them as function keys: with macOS's default "Use
    /// F1, F2, etc. keys as standard function keys" OFF, the system claims the
    /// press for brightness or media and no app sees it. `docs/dictation.md`
    /// carries that caveat, since a shortcut that registers and never fires
    /// looks like a bug from the outside.
    ///
    /// What arrives here is already `normalized`: ShortcutRecorder reports
    /// F1-F20 with `NSFunctionKeyMask` set, and the mask above is what turns
    /// that into "no modifier" (`testValidation_stripsTheRecorderFunctionKeyBit`).
    static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    static func persistenceErrorMessage(for shortcut: DictationShortcut) -> String? {
        if shortcut.keyCode > UInt32(UInt16.max) {
            return "Shortcut key is not supported."
        }

        if normalizedModifierFlags(shortcut.carbonModifierFlags) == 0,
            !isFunctionKey(shortcut.keyCode)
        {
            return "Shortcut needs a modifier key. Only function keys work on their own."
        }

        return nil
    }

    static func validationErrorMessage(for shortcut: DictationShortcut) -> String? {
        if let persistenceError = persistenceErrorMessage(for: shortcut) {
            return persistenceError
        }

        let normalized = shortcut.normalized
        switch (normalized.keyCode, normalized.carbonModifierFlags) {
        case (UInt32(kVK_Space), UInt32(cmdKey)):
            return "Command-Space is reserved by Spotlight."
        case (UInt32(kVK_Tab), UInt32(cmdKey)):
            return "Command-Tab is reserved for app switching."
        case (UInt32(kVK_ANSI_Q), UInt32(cmdKey)):
            return "Command-Q is reserved for quitting apps."
        case (UInt32(kVK_ANSI_W), UInt32(cmdKey)):
            return "Command-W is reserved for closing windows."
        default:
            return nil
        }
    }
}
