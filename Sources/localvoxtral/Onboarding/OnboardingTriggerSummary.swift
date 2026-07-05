import Carbon.HIToolbox
import Foundation

/// A short, human-readable summary of the currently configured dictation
/// trigger, derived from `SettingsStore` the same way `registerCurrentHotKeys`
/// resolves what to register. Pure and value-typed so the Finish page can render
/// it and tests can assert it without touching AppKit.
struct DictationTriggerSummary: Equatable {
    /// The prominent trigger label, e.g. "⌥Space" or "Fn / Globe".
    var primary: String
    /// One line explaining how to use it.
    var explanation: String
    /// True when the trigger already is a single modifier key, so the Finish
    /// page skips the tip suggesting one.
    var isModifierOnly = false

    @MainActor
    static func make(settings: SettingsStore) -> DictationTriggerSummary {
        if settings.modifierOnlyHotKeyEnabled {
            return DictationTriggerSummary(
                primary: settings.modifierOnlyHotKeyModifier.displayName,
                explanation: "Tap for Overlay Buffer, hold for Live Auto-Paste.",
                isModifierOnly: true
            )
        }

        let overlay = settings.overlayBufferShortcut
        let livePaste = settings.livePasteShortcut

        if let overlay {
            var explanation = "Press it in any text field to start dictating."
            if let livePaste {
                explanation +=
                    " (\(DictationShortcutFormatter.string(for: livePaste)) for Live Auto-Paste.)"
            }
            return DictationTriggerSummary(
                primary: DictationShortcutFormatter.string(for: overlay),
                explanation: explanation
            )
        }

        if let livePaste {
            return DictationTriggerSummary(
                primary: DictationShortcutFormatter.string(for: livePaste),
                explanation: "Hold it in any text field to dictate with Live Auto-Paste."
            )
        }

        return DictationTriggerSummary(
            primary: "Menu bar",
            explanation: "No shortcut is set — start dictation from the menu bar icon."
        )
    }
}

/// Renders a `DictationShortcut` as a compact glyph string (e.g. "⌘⇧D").
enum DictationShortcutFormatter {
    static func string(for shortcut: DictationShortcut) -> String {
        modifierGlyphs(shortcut.carbonModifierFlags) + keyLabel(for: shortcut.keyCode)
    }

    /// Modifier glyphs in the conventional macOS display order: ⌃⌥⇧⌘.
    private static func modifierGlyphs(_ flags: UInt32) -> String {
        var glyphs = ""
        if flags & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if flags & UInt32(optionKey) != 0 { glyphs += "⌥" }
        if flags & UInt32(shiftKey) != 0 { glyphs += "⇧" }
        if flags & UInt32(cmdKey) != 0 { glyphs += "⌘" }
        return glyphs
    }

    private static func keyLabel(for keyCode: UInt32) -> String {
        if let label = keyLabels[keyCode] {
            return label
        }
        return "Key \(keyCode)"
    }

    private static let keyLabels: [UInt32: String] = {
        var labels: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
            UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
            UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
            UInt32(kVK_ANSI_Grave): "`",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
            UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
            UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "Escape",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
            UInt32(kVK_PageUp): "Page Up", UInt32(kVK_PageDown): "Page Down",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        return labels
    }()
}
