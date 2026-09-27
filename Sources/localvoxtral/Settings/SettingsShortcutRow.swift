import SwiftUI

/// A row whose control is a shortcut recorder, with an optional Clear or
/// Reset button beside it. Every shortcut row in Settings goes through here so
/// they all centre the title against the 24pt recorder, as the toggle rows
/// do; `.top` pinned it to the recorder's top edge instead (#887).
struct SettingsShortcutRow<Footer: View>: View {
    struct ButtonAction {
        let title: String
        let isDisabled: Bool
        let perform: () -> Void
    }

    let title: String
    @Binding var shortcut: DictationShortcut?
    @Binding var validationError: String?
    var acceptsModifierChord = false
    var button: ButtonAction?
    @ViewBuilder var footer: Footer

    var body: some View {
        SettingsFieldRow(title: title) {
            HStack(alignment: .center, spacing: 8) {
                ShortcutRecorderField(
                    shortcut: $shortcut,
                    validationError: $validationError,
                    fixedWidth: 132,
                    acceptsModifierChord: acceptsModifierChord
                )
                .frame(height: 24, alignment: .leading)

                if let button {
                    Button(button.title, action: button.perform)
                        .disabled(button.isDisabled)
                }
            }
        } footer: {
            footer
        }
    }
}
