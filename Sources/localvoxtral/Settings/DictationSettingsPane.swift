import AppKit
import SwiftUI

struct DictationSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let dictationShortcutBinding: Binding<DictationShortcut?>
    @Binding var shortcutValidationError: String?

    /// The Trigger group's Learn more: what a tap and a hold do, and Tab.
    private static let shortcutsDocsURL = DocsLink.page("docs/dictation/#shortcuts")
    /// The Overlay Buffer group's Learn more: what keeping words on their
    /// line trades for.
    private static let overlayWordHoldDocsURL = DocsLink.page("docs/dictation/#keeping-words-on-their-line")
    /// The Output group's Learn more: the send phrases, where they press
    /// Return, and how a dictation stops on one.
    private static let agentsDocsURL = DocsLink.page("docs/agents/")

    private var dictationOutputModeBinding: Binding<DictationOutputMode> {
        Binding(
            get: { settings.dictationOutputMode },
            set: { newValue in
                viewModel.engines.applyDictationOutputModeChange(newValue)
            }
        )
    }
    /// The slider works in `Double`; the setting is a whole line count.
    private var overlayBufferVisibleLinesBinding: Binding<Double> {
        Binding(
            get: { Double(settings.overlayBufferVisibleLines) },
            set: { settings.overlayBufferVisibleLines = Int($0.rounded()) }
        )
    }
    @State private var overlayValidationError: String?
    @State private var livePasteValidationError: String?
    @State private var copyLastDictationValidationError: String?
    @State private var answerAgentValidationError: String?
    @State private var quickCaptureValidationError: String?
    @State private var dictationChordValidationError: String?
    @State private var pendingShortcutMove: PendingShortcutMove?

    /// A recording that would take the other mode's key, held until the user
    /// answers. Nothing is written while it sits here.
    private struct PendingShortcutMove {
        let target: DictationOutputMode
        let takenFrom: DictationOutputMode
        let shortcut: DictationShortcut
    }

    /// Every write to either slot goes through here, the recorder and the
    /// Reset button alike. Reset writes the default shortcut without touching
    /// the recorder, so routing it anywhere else is how the conflict this pane
    /// exists to prevent gets back in.
    private func assignOverlayBufferShortcut(_ shortcut: DictationShortcut?) {
        apply(viewModel.shortcuts.requestOverlayBufferShortcut(shortcut), target: .overlayBuffer)
    }

    private func assignLivePasteShortcut(_ shortcut: DictationShortcut?) {
        apply(viewModel.shortcuts.requestLivePasteShortcut(shortcut), target: .liveAutoPaste)
    }

    private func apply(
        _ assignment: DictationViewModel.ShortcutAssignment,
        target: DictationOutputMode
    ) {
        switch assignment {
        case .applied:
            pendingShortcutMove = nil
        case .needsMoveConfirmation(let shortcut, let takenFrom):
            pendingShortcutMove = PendingShortcutMove(
                target: target,
                takenFrom: takenFrom,
                shortcut: shortcut
            )
        case .refused(let message):
            pendingShortcutMove = nil
            switch target {
            case .overlayBuffer: overlayValidationError = message
            case .liveAutoPaste: livePasteValidationError = message
            }
        }
    }

    private func assignCopyLastDictationShortcut(_ shortcut: DictationShortcut?) {
        copyLastDictationValidationError = viewModel.shortcuts.requestCopyLastDictationShortcut(shortcut)
    }

    private func assignAnswerAgentShortcut(_ shortcut: DictationShortcut?) {
        answerAgentValidationError = viewModel.shortcuts.requestAnswerAgentShortcut(shortcut)
    }

    /// Turning the needs-you cue on is when macOS is asked to allow its
    /// banner; turning it off empties the queue at once.
    private var agentAttentionBinding: Binding<Bool> {
        Binding(
            get: { settings.agentAttentionEnabled },
            set: { isOn in
                settings.agentAttentionEnabled = isOn
                if isOn {
                    viewModel.agentAttention?.announcer?.requestPermission()
                } else {
                    viewModel.agentAttention?.tracker.clear()
                    viewModel.agentAttention?.clearDrafts()
                }
            }
        )
    }

    private var answerAgentShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.answerAgentShortcut },
            set: { assignAnswerAgentShortcut($0) }
        )
    }

    static let dictationChordNeedsModifiersMessage = "Press two modifier keys together."

    /// The Chord row's recorder also takes a modifier+key shortcut; this slot
    /// refuses one, since only the keyboard-shortcut trigger registers keys.
    private var dictationChordBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.dictationChord.map(DictationShortcut.init(chord:)) },
            set: { shortcut in
                if let shortcut, shortcut.modifierChord == nil {
                    dictationChordValidationError = Self.dictationChordNeedsModifiersMessage
                    return
                }
                dictationChordValidationError = viewModel.shortcuts.requestDictationChord(shortcut?.modifierChord)
            }
        )
    }

    private func assignQuickCaptureShortcut(_ shortcut: DictationShortcut?) {
        quickCaptureValidationError = viewModel.shortcuts.requestQuickCaptureShortcut(shortcut)
    }

    private var quickCaptureShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.quickCaptureShortcut },
            set: { assignQuickCaptureShortcut($0) }
        )
    }

    private var copyLastDictationShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.copyLastDictationShortcut },
            set: { assignCopyLastDictationShortcut($0) }
        )
    }

    private var overlayBufferShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.overlayBufferShortcut },
            set: { assignOverlayBufferShortcut($0) }
        )
    }

    private var livePasteShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.livePasteShortcut },
            set: { assignLivePasteShortcut($0) }
        )
    }

    var body: some View {
        SettingsPage(tab: .dictation) {
            SettingsGroup(title: "Trigger", learnMoreURL: Self.shortcutsDocsURL) {
                SettingsFieldRow(title: "Method") {
                    Picker("", selection: Binding(
                        get: { settings.modifierOnlyHotKeyEnabled },
                        set: { newValue in
                            viewModel.shortcuts.applyDictationTriggerModeChange(
                                modifierOnlyEnabled: newValue
                            )
                        }
                    )) {
                        Text("Modifier keys").tag(true)
                        Text("Keyboard shortcuts").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if settings.modifierOnlyHotKeyEnabled {
                    // Stacked: beside the four-segment picker the inline
                    // label was squeezed to a letter or two per line (#890).
                    SettingsFieldRow(title: "Modifier key", layout: .stacked) {
                        Picker("", selection: Binding(
                            get: { settings.modifierOnlyHotKeyModifier },
                            set: { newValue in
                                dictationChordValidationError = nil
                                viewModel.shortcuts.selectModifierKey(newValue)
                            }
                        )) {
                            ForEach(ModifierOnlyHotKeyManager.ModifierKey.allCases) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if settings.modifierOnlyHotKeyModifier == .chord {
                        SettingsShortcutRow(
                            title: "Chord keys",
                            shortcut: dictationChordBinding,
                            validationError: $dictationChordValidationError,
                            acceptsModifierChord: true
                        ) {
                            if let dictationChordValidationError {
                                SettingsInlineMessage(dictationChordValidationError, color: .red)
                            } else if settings.dictationChord == nil {
                                SettingsInlineMessage(
                                    "Not set. Record one to enable.",
                                    color: .secondary
                                )
                            }
                        }
                    }

                    SettingsFieldRow(title: "Hold delay") {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { settings.modifierOnlyHoldDelay },
                                    set: { newValue in
                                        settings.modifierOnlyHoldDelay = newValue
                                        viewModel.shortcuts.applyHotKeySettingsChange()
                                    }
                                ),
                                in: 0.1...0.8,
                                step: 0.05
                            )
                            // A Slider has no intrinsic width; in a trailing
                            // control column it would collapse, so both sliders
                            // in this pane are given the same explicit track.
                            .frame(width: SettingsLayout.sliderWidth)

                            Text("\(Int(settings.modifierOnlyHoldDelay * 1000))ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                } else {
                    SettingsShortcutRow(
                        title: "Dictation shortcut",
                        shortcut: overlayBufferShortcutBinding,
                        validationError: $overlayValidationError,
                        button: .init(
                            title: "Reset",
                            isDisabled: settings.overlayBufferShortcut
                                == SettingsStore.defaultDictationShortcut
                        ) {
                            overlayValidationError = nil
                            assignOverlayBufferShortcut(SettingsStore.defaultDictationShortcut)
                        }
                    ) {
                        // A footer, not a third item in the control column: a
                        // validation sentence right-aligned under the recorder
                        // wraps in a 200pt column and reads as unattached.
                        if let overlayValidationError {
                            SettingsInlineMessage(overlayValidationError, color: .red)
                        } else if settings.overlayBufferShortcut == nil {
                            SettingsInlineMessage(
                                "Not set. Record one to enable.",
                                color: .secondary
                            )
                        }
                    }

                    SettingsFieldRow(
                        title: "Shortcut action"
                    ) {
                        Picker("", selection: $settings.dictationShortcutMode) {
                            ForEach(DictationShortcutMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }

            SettingsGroup(title: "Output", learnMoreURL: Self.agentsDocsURL) {
                SettingsFieldRow(title: "Copy on stop") {
                    Toggle("", isOn: $settings.autoCopyEnabled)
                        .labelsHidden()
                }

                SendPhrasesRow(settings: settings)

                // Overlay Buffer only: Live Auto-Paste presses Return on the
                // segment's final and never waits (#1009).
                SettingsFieldRow(title: "Wait before pressing Return") {
                    Picker("", selection: $settings.spokenStopWait) {
                        ForEach(SpokenStopWait.allCases) { wait in
                            Text(wait.displayName).tag(wait)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                // The needs-you cue (#717): a sound, a banner and the menu
                // bar icon when a coding agent waits for you, and the waiting
                // sessions among the overlay's destinations (#840).
                SettingsFieldRow(title: "Tell me when an agent needs you") {
                    Toggle("", isOn: agentAttentionBinding)
                        .labelsHidden()
                }

                SettingsFieldRow(title: "Menu bar mark when an agent needs you") {
                    Picker("", selection: $settings.agentAttentionMark) {
                        ForEach(AgentAttentionMark.allCases) { mark in
                            Text(mark.displayName).tag(mark)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!settings.agentAttentionEnabled)
                }

                // Optional: opens a dictation in the pane of the session that
                // needs you, as Tab to it would.
                SettingsShortcutRow(
                    title: "Answer the agent that needs you",
                    shortcut: answerAgentShortcutBinding,
                    validationError: $answerAgentValidationError,
                    acceptsModifierChord: true,
                    button: .init(title: "Clear", isDisabled: settings.answerAgentShortcut == nil) {
                        answerAgentValidationError = nil
                        assignAnswerAgentShortcut(nil)
                    }
                ) {
                    if let answerAgentValidationError {
                        SettingsInlineMessage(answerAgentValidationError, color: .red)
                    }
                }

                // Optional: opens a dictation with the Inbox picked, as Tab to
                // it would (#840). Its words never reach the focused app.
                SettingsShortcutRow(
                    title: "Quick capture to Inbox",
                    shortcut: quickCaptureShortcutBinding,
                    validationError: $quickCaptureValidationError,
                    acceptsModifierChord: true,
                    button: .init(title: "Clear", isDisabled: settings.quickCaptureShortcut == nil) {
                        quickCaptureValidationError = nil
                        assignQuickCaptureShortcut(nil)
                    }
                ) {
                    if let quickCaptureValidationError {
                        SettingsInlineMessage(quickCaptureValidationError, color: .red)
                    }
                }

                SettingsFieldRow(title: "Lower other audio while dictating") {
                    Toggle("", isOn: $settings.audioDuckingEnabled)
                        .labelsHidden()
                }

                SettingsFieldRow(title: "Fade") {
                    HStack(spacing: 8) {
                        Slider(
                            value: $settings.audioDuckingFadeDuration,
                            in: SettingsStore.audioDuckingFadeDurationRange,
                            step: 0.1
                        )
                        .frame(width: SettingsLayout.sliderWidth)

                        Text("\(Int(settings.audioDuckingFadeDuration * 1000))ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    // Dimmed rather than hidden: the pane's row set stays put
                    // whatever the toggle says (owner rule, 2026-07-04).
                    .disabled(!settings.audioDuckingEnabled)
                }
            }

            SettingsGroup(title: "Overlay Buffer", learnMoreURL: Self.overlayWordHoldDocsURL) {
                SettingsFieldRow(
                    title: "Font size"
                ) {
                    HStack(spacing: 8) {
                        Slider(
                            value: $settings.overlayBufferFontSize,
                            in: OverlayLayoutMetrics.minimumBodyFontSize
                                ... OverlayLayoutMetrics.maximumBodyFontSize,
                            step: 1
                        )
                        .frame(width: SettingsLayout.sliderWidth)

                        Text("\(Int(settings.overlayBufferFontSize))pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                SettingsFieldRow(title: "Lines before scrolling") {
                    HStack(spacing: 8) {
                        Slider(
                            value: overlayBufferVisibleLinesBinding,
                            in: Double(OverlayLayoutMetrics.minimumVisibleLines)
                                ... Double(OverlayLayoutMetrics.maximumVisibleLines),
                            step: 1
                        )
                        .frame(width: SettingsLayout.sliderWidth)

                        Text("\(settings.overlayBufferVisibleLines)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                SettingsFieldRow(title: "Keep words from jumping to the next line") {
                    Picker("", selection: $settings.overlayBufferWordHold) {
                        ForEach(OverlayWordHold.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                SettingsFieldRow(title: "Stop dictating after silence") {
                    Picker("", selection: $settings.overlayBufferSilenceAutoStop) {
                        ForEach(SilenceAutoStop.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                SettingsFieldRow(title: "Say a send phrase to press Return in terminals and Claude Desktop") {
                    Toggle("", isOn: $settings.overlaySpokenSendEnabled)
                        .labelsHidden()
                }

                SettingsFieldRow(
                    title: "Position",
                    status: settings.overlayBufferPlacement == nil
                        ? "Follows the focused window; drag the overlay to pin it" : nil
                ) {
                    if settings.overlayBufferPlacement != nil {
                        Button("Re-anchor") { settings.overlayBufferPlacement = nil }
                    }
                }
            }

            // Live Auto-Paste (#840): off unless a key is set here. It types
            // as you speak, so the overlay's destinations never apply to it.
            SettingsGroup(title: "Advanced") {
                if settings.modifierOnlyHotKeyEnabled {
                    SettingsFieldRow(title: "Hold the key for Live Auto-Paste") {
                        Toggle("", isOn: $settings.modifierHoldLiveAutoPaste)
                            .labelsHidden()
                    }
                } else {
                    SettingsShortcutRow(
                        title: "Live Auto-Paste shortcut",
                        shortcut: livePasteShortcutBinding,
                        validationError: $livePasteValidationError,
                        button: .init(title: "Clear", isDisabled: settings.livePasteShortcut == nil) {
                            livePasteValidationError = nil
                            assignLivePasteShortcut(nil)
                        }
                    ) {
                        if let livePasteValidationError {
                            SettingsInlineMessage(livePasteValidationError, color: .red)
                        } else if settings.livePasteShortcut == nil {
                            SettingsInlineMessage(
                                "Not set. Record one to enable.",
                                color: .secondary
                            )
                        }
                    }
                }

                // Under Advanced (#840), apart from the Overlay Buffer
                // toggle, so its title names the mode.
                SettingsFieldRow(title: "Say a send phrase in Live Auto-Paste to press Return") {
                    Toggle("", isOn: $settings.liveSpokenSendEnabled)
                        .labelsHidden()
                }

                SettingsFieldRow(title: "Menu bar mode") {
                    Picker("", selection: dictationOutputModeBinding) {
                        ForEach(DictationOutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingsShortcutRow(
                    title: "Copy last dictation",
                    shortcut: copyLastDictationShortcutBinding,
                    validationError: $copyLastDictationValidationError,
                    acceptsModifierChord: true,
                    button: .init(title: "Clear", isDisabled: settings.copyLastDictationShortcut == nil) {
                        copyLastDictationValidationError = nil
                        assignCopyLastDictationShortcut(nil)
                    }
                ) {
                    if let copyLastDictationValidationError {
                        SettingsInlineMessage(copyLastDictationValidationError, color: .red)
                    }
                }
            }
        }
        // Carbon refuses the same key twice on one target, so the second mode
        // can only have it if the first gives it up. Asking beats the silent
        // failure that came before: the recorder used to accept the key and
        // registration then died, blaming whichever slot registered second.
        .alert(
            pendingShortcutMove.map {
                "\(DictationShortcutFormatter.string(for: $0.shortcut)) is the \($0.takenFrom.displayName) shortcut"
            } ?? "",
            isPresented: Binding(
                get: { pendingShortcutMove != nil },
                set: { if !$0 { pendingShortcutMove = nil } }
            ),
            presenting: pendingShortcutMove
        ) { move in
            Button("Move") {
                switch move.target {
                case .overlayBuffer:
                    viewModel.shortcuts.moveShortcutToOverlayBuffer(move.shortcut)
                case .liveAutoPaste:
                    viewModel.shortcuts.moveShortcutToLivePaste(move.shortcut)
                }
                pendingShortcutMove = nil
            }
            Button("Cancel", role: .cancel) {
                pendingShortcutMove = nil
            }
        } message: { move in
            Text("Move it to \(move.target.displayName)? \(move.takenFrom.displayName) will have no shortcut.")
        }
    }
}

/// The send phrases (#839), comma-separated. A list is saved only when every
/// phrase passes `SendTriggerPhrases.validate`; otherwise the saved list
/// stays and the footer says why.
struct SendPhrasesRow: View {
    @Bindable var settings: SettingsStore
    @State private var draft: String?
    @State private var refusal: String?
    @FocusState private var focused: Bool

    init(settings: SettingsStore, draft: String? = nil, refusal: String? = nil) {
        self.settings = settings
        _draft = State(initialValue: draft)
        _refusal = State(initialValue: refusal)
    }

    private var saved: String { settings.spokenSendTriggerPhrases.joined(separator: ", ") }

    var body: some View {
        SettingsFieldRow(title: "Send phrases") {
            TextField("send it, send now", text: Binding(
                get: { draft ?? saved },
                set: { draft = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: SettingsLayout.textFieldWidth)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { save() }
            }
        } footer: {
            if let refusal {
                SettingsInlineMessage(refusal, color: .red)
            }
        }
    }

    private func save() {
        guard let draft else { return }
        switch SendTriggerPhrases.validate(SendTriggerPhrases.split(draft)) {
        case .success(let phrases):
            settings.spokenSendTriggerPhrases = phrases
            self.draft = nil
            refusal = nil
        case .failure(let reason):
            refusal = reason.message
        }
    }
}
