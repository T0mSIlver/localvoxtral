import AppKit
import ShortcutRecorder
import SwiftUI

struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: DictationShortcut?
    @Binding var validationError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> RecorderControl {
        let control = RecorderControl(frame: .zero)
        control.delegate = context.coordinator
        control.target = context.coordinator
        control.action = #selector(Coordinator.handleRecorderChange(_:))
        control.drawsASCIIEquivalentOfShortcut = true
        control.allowsModifierFlagsOnlyShortcut = false
        control.allowsDeleteToClearShortcutAndEndRecording = true
        control.allowsEscapeToCancelRecording = true
        control.set(
            allowedModifierFlags: CocoaModifierFlagsMask,
            requiredModifierFlags: [],
            allowsEmptyModifierFlags: false
        )
        context.coordinator.updateControlValue(control, from: shortcut)
        return control
    }

    func updateNSView(_ nsView: RecorderControl, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateControlValue(nsView, from: shortcut)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency RecorderControlDelegate {
        var parent: ShortcutRecorderField
        private let validator = ShortcutValidator(delegate: nil)
        private var isApplyingProgrammaticUpdate = false

        init(parent: ShortcutRecorderField) {
            self.parent = parent
        }

        func recorderControl(_ control: RecorderControl, canRecord shortcut: Shortcut) -> Bool {
            let candidate = DictationShortcut(
                keyCode: shortcut.carbonKeyCode,
                carbonModifierFlags: shortcut.carbonModifierFlags
            ).normalized

            if let message = DictationShortcutValidation.validationErrorMessage(for: candidate) {
                parent.validationError = message
                return false
            }

            do {
                try validator.validate(shortcut: shortcut)
            } catch {
                parent.validationError = error.localizedDescription
                return false
            }

            parent.validationError = nil
            return true
        }

        @objc
        func handleRecorderChange(_ sender: RecorderControl) {
            guard !isApplyingProgrammaticUpdate else { return }

            if let value = sender.objectValue {
                let recordedShortcut = DictationShortcut(
                    keyCode: value.carbonKeyCode,
                    carbonModifierFlags: value.carbonModifierFlags
                ).normalized

                if parent.shortcut != recordedShortcut {
                    parent.shortcut = recordedShortcut
                }
                parent.validationError = nil
                return
            }

            if parent.shortcut != nil {
                parent.shortcut = nil
            }
            parent.validationError = nil
        }

        func updateControlValue(_ control: RecorderControl, from shortcut: DictationShortcut?) {
            let desiredValue = shortcut.flatMap(Self.toRecorderShortcut)
            let currentValue = control.objectValue

            if Self.shortcutsEqual(currentValue, desiredValue) {
                return
            }

            isApplyingProgrammaticUpdate = true
            control.objectValue = desiredValue
            isApplyingProgrammaticUpdate = false
        }

        private static func toRecorderShortcut(_ shortcut: DictationShortcut) -> Shortcut? {
            guard let keyCode = KeyCode(rawValue: UInt16(shortcut.keyCode)) else {
                return nil
            }

            return Shortcut(
                code: keyCode,
                modifierFlags: carbonToCocoaFlags(shortcut.carbonModifierFlags),
                characters: nil,
                charactersIgnoringModifiers: nil
            )
        }

        private static func shortcutsEqual(_ lhs: Shortcut?, _ rhs: Shortcut?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (lhs?, rhs?):
                return lhs.carbonKeyCode == rhs.carbonKeyCode
                    && lhs.carbonModifierFlags == rhs.carbonModifierFlags
            default:
                return false
            }
        }
    }
}
