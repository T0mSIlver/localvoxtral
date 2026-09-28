import AppKit
import ShortcutRecorder
import SwiftUI

struct ShortcutRecorderField: View {
    @Binding var shortcut: DictationShortcut?
    @Binding var validationError: String?
    var fixedWidth: CGFloat? = nil
    /// Also records a modifier-only chord, such as both Shift keys pressed
    /// together (#831). Only the action slots take one.
    var acceptsModifierChord = false

    @Environment(\.shortcutRecorderStandIn) private var drawsStandIn

    var body: some View {
        if drawsStandIn {
            ShortcutRecorderStandIn(fixedWidth: fixedWidth)
        } else {
            ShortcutRecorderControl(
                shortcut: $shortcut, validationError: $validationError, fixedWidth: fixedWidth,
                acceptsModifierChord: acceptsModifierChord)
        }
    }
}

extension EnvironmentValues {
    /// Draws a static box where each shortcut recorder would be. For the
    /// snapshot tests: ShortcutRecorder's control loads data assets that only
    /// `package_app.sh` compiles (`actool`), and without them it traps.
    @Entry var shortcutRecorderStandIn = false
}

private struct ShortcutRecorderStandIn: View {
    var fixedWidth: CGFloat?

    var body: some View {
        Text("Shortcut")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: fixedWidth, height: 22)
            .frame(maxWidth: fixedWidth == nil ? .infinity : nil)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3]))
            )
    }
}

private struct ShortcutRecorderControl: NSViewRepresentable {
    static let chordTooSlowMessage = "Press the keys together."
    @Binding var shortcut: DictationShortcut?
    @Binding var validationError: String?
    var fixedWidth: CGFloat? = nil
    var acceptsModifierChord = false

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ChordRecorderControl {
        let control = ChordRecorderControl(frame: .zero)
        control.acceptsModifierChord = acceptsModifierChord
        control.onChordRecorded = { [weak coordinator = context.coordinator] chord in
            coordinator?.handleChordRecorded(chord)
        }
        control.onChordTooSlow = { [weak coordinator = context.coordinator] in
            coordinator?.parent.validationError = Self.chordTooSlowMessage
        }
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.delegate = context.coordinator
        control.target = context.coordinator
        control.action = #selector(Coordinator.handleRecorderChange(_:))
        control.drawsASCIIEquivalentOfShortcut = true
        control.allowsModifierFlagsOnlyShortcut = false
        control.allowsDeleteToClearShortcutAndEndRecording = true
        control.allowsEscapeToCancelRecording = true
        // Bare keys reach `canRecord`, which is where the real rule lives:
        // `DictationShortcutValidation` accepts a function key on its own and
        // rejects every other unmodified key with a message. Leaving this
        // false would make the control swallow F13 before we ever see it.
        control.set(
            allowedModifierFlags: CocoaModifierFlagsMask,
            requiredModifierFlags: [],
            allowsEmptyModifierFlags: true
        )
        if let fixedWidth {
            control.widthAnchor.constraint(equalToConstant: fixedWidth).isActive = true
        }
        context.coordinator.updateControlValue(control, from: shortcut)
        return control
    }

    func updateNSView(_ nsView: ChordRecorderControl, context: Context) {
        context.coordinator.parent = self
        nsView.acceptsModifierChord = acceptsModifierChord
        context.coordinator.updateControlValue(nsView, from: shortcut)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency RecorderControlDelegate {
        var parent: ShortcutRecorderControl
        private let validator = ShortcutValidator(delegate: nil)
        private var isApplyingProgrammaticUpdate = false

        init(parent: ShortcutRecorderControl) {
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

            // Cleared before the write, not after: the binding's setter can
            // refuse the key and say why in `validationError`.
            parent.validationError = nil
            if let value = sender.objectValue {
                let recordedShortcut = DictationShortcut(
                    keyCode: value.carbonKeyCode,
                    carbonModifierFlags: value.carbonModifierFlags
                ).normalized

                if parent.shortcut != recordedShortcut {
                    parent.shortcut = recordedShortcut
                }
                return
            }

            if parent.shortcut != nil {
                parent.shortcut = nil
            }
        }

        func handleChordRecorded(_ chord: ModifierChord) {
            parent.validationError = nil
            let recorded = DictationShortcut(chord: chord)
            if parent.shortcut != recorded {
                parent.shortcut = recorded
            }
        }

        func updateControlValue(_ control: ChordRecorderControl, from shortcut: DictationShortcut?) {
            if control.chord != shortcut?.modifierChord {
                control.chord = shortcut?.modifierChord
            }
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
            guard shortcut.modifierChord == nil,
                  let keyCode = KeyCode(rawValue: UInt16(shortcut.keyCode)) else {
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

/// ShortcutRecorder's control, taught to record a modifier-only chord too
/// (#831): while recording, press two modifier keys or more together and
/// let go, with no other key, and the chord is set. A modifier+key shortcut
/// records as before. The control can't hold a chord as its value, so it
/// shows `chord` as its label instead.
final class ChordRecorderControl: RecorderControl {
    var acceptsModifierChord = false
    var onChordRecorded: ((ModifierChord) -> Void)?
    var onChordTooSlow: (() -> Void)?
    var chord: ModifierChord? {
        didSet { needsDisplay = true }
    }

    private var chordRecorder = ModifierChordRecorder()

    override func beginRecording() -> Bool {
        chordRecorder.reset()
        return super.beginRecording()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard acceptsModifierChord, isRecording else { return }
        let flags = event.modifierFlags
        let outcome = chordRecorder.modifiersChanged(
            held: SidedModifier.held(inDeviceFlags: flags.rawValue),
            otherModifierHeld: flags.contains(.function) || flags.contains(.capsLock),
            at: event.timestamp)
        switch outcome {
        case .none:
            break
        case .chord(let chord):
            endRecording()
            onChordRecorded?(chord)
        case .tooSlow:
            onChordTooSlow?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if isRecording { chordRecorder.keyPressed() }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording { chordRecorder.keyPressed() }
        return super.performKeyEquivalent(with: event)
    }

    override var drawingLabel: String {
        if !isRecording, objectValue == nil, let chord {
            return chord.displayName
        }
        return super.drawingLabel
    }
}
