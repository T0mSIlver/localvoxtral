import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var viewModel: DictationViewModel
    @State private var shortcutValidationError: String?

    private var mlxTranscriptionDelaySecondsBinding: Binding<Double> {
        Binding(
            get: { Double(settings.mlxAudioTranscriptionDelayMilliseconds) / 1000.0 },
            set: { newValue in
                let milliseconds = Int((newValue * 1000.0).rounded())
                settings.mlxAudioTranscriptionDelayMilliseconds = min(max(milliseconds, 400), 2_000)
            }
        )
    }

    private var mlxTranscriptionDelayLabel: String {
        String(format: "%.2fs", Double(settings.mlxAudioTranscriptionDelayMilliseconds) / 1000.0)
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: {
                settings.endpointURL(for: settings.realtimeProvider)
            },
            set: { newValue in
                switch settings.realtimeProvider {
                case .realtimeAPI:
                    settings.realtimeAPIEndpointURL = newValue
                case .mlxAudio:
                    settings.mlxAudioEndpointURL = newValue
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                settings.modelName(for: settings.realtimeProvider)
            },
            set: { newValue in
                switch settings.realtimeProvider {
                case .realtimeAPI:
                    settings.realtimeAPIModelName = newValue
                case .mlxAudio:
                    settings.mlxAudioModelName = newValue
                }
            }
        )
    }

    private var dictationShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: {
                settings.dictationShortcut
            },
            set: { newValue in
                viewModel.updateDictationShortcut(newValue)
            }
        )
    }

    private var overlayBufferShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.overlayBufferShortcut },
            set: { newValue in
                viewModel.updateOverlayBufferShortcut(newValue)
            }
        )
    }

    private var livePasteShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.livePasteShortcut },
            set: { newValue in
                viewModel.updateLivePasteShortcut(newValue)
            }
        )
    }

    var body: some View {
        TabView {
            ConnectionSettingsPane(
                settings: settings,
                endpointBinding: endpointBinding,
                modelBinding: modelBinding,
                mlxTranscriptionDelaySecondsBinding: mlxTranscriptionDelaySecondsBinding,
                mlxTranscriptionDelayLabel: mlxTranscriptionDelayLabel
            )
            .tabItem {
                Label("Realtime Endpoint", systemImage: "network")
            }

            DictationSettingsPane(
                settings: settings,
                viewModel: viewModel,
                dictationShortcutBinding: dictationShortcutBinding,
                overlayBufferShortcutBinding: overlayBufferShortcutBinding,
                livePasteShortcutBinding: livePasteShortcutBinding,
                shortcutValidationError: $shortcutValidationError
            )
            .tabItem {
                Label("Dictation", systemImage: "mic")
            }

            TextProcessingSettingsPane(
                settings: settings,
                viewModel: viewModel
            )
            .tabItem {
                Label("Text Processing", systemImage: "text.badge.checkmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum SettingsLayout {
    static let pageSpacing: CGFloat = 16
    static let pagePadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 10
    static let cardSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 14
    static let labelWidth: CGFloat = 128
    static let cornerRadius: CGFloat = 18
}

private struct ConnectionSettingsPane: View {
    @Bindable var settings: SettingsStore
    let endpointBinding: Binding<String>
    let modelBinding: Binding<String>
    let mlxTranscriptionDelaySecondsBinding: Binding<Double>
    let mlxTranscriptionDelayLabel: String

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Backend") {
                SettingsFieldRow(title: "Provider") {
                    Picker("", selection: $settings.realtimeProvider) {
                        ForEach(SettingsStore.RealtimeProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingsFieldRow(title: "Realtime endpoint") {
                    TextField(settings.endpointPlaceholder, text: endpointBinding)
                        .textFieldStyle(.roundedBorder)
                }

                SettingsFieldRow(title: "Model") {
                    TextField(settings.modelPlaceholder, text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                }

                if settings.realtimeProvider == .realtimeAPI {
                    SettingsFieldRow(title: "API key") {
                        SecureField("Required for remote providers", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            SettingsGroup(title: "Streaming") {
                if settings.realtimeProvider == .realtimeAPI {
                    SettingsFieldRow(title: "Commit interval") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Slider(
                                    value: $settings.commitIntervalSeconds,
                                    in: 0.1...1.0,
                                    step: 0.1
                                )
                                Text(String(format: "%.2fs", settings.commitIntervalSeconds))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                            }

                            SettingsHelpText(
                                "How often finalized transcript chunks are requested from the realtime server."
                            )
                        }
                    }
                } else {
                    SettingsFieldRow(title: "Transcription delay") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Slider(
                                    value: mlxTranscriptionDelaySecondsBinding,
                                    in: 0.4...2.0,
                                    step: 0.1
                                )
                                Text(mlxTranscriptionDelayLabel)
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                            }

                            SettingsHelpText(
                                "How long mlx-audio waits for right-context before emitting tokens."
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct DictationSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let dictationShortcutBinding: Binding<DictationShortcut?>
    let overlayBufferShortcutBinding: Binding<DictationShortcut?>
    let livePasteShortcutBinding: Binding<DictationShortcut?>
    @Binding var shortcutValidationError: String?
    @State private var overlayValidationError: String?
    @State private var livePasteValidationError: String?

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Behavior") {
                SettingsFieldRow(title: "Output mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $settings.dictationOutputMode) {
                            ForEach(DictationOutputMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsHelpText(settings.dictationOutputMode.description)
                    }
                }

                SettingsFieldRow(title: "Shortcut behavior") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $settings.dictationShortcutMode) {
                            ForEach(DictationShortcutMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsHelpText(settings.dictationShortcutMode.description)
                    }
                }

                ToggleSettingRow(
                    title: "Auto-copy final segment",
                    subtitle: "Copy the finalized segment to the clipboard after dictation stops.",
                    isOn: $settings.autoCopyEnabled
                )

                ToggleSettingRow(
                    title: "Audio ducking",
                    subtitle: "Fade system volume down when dictation starts, restore when it stops.",
                    isOn: $settings.audioDuckingEnabled
                )

                if settings.audioDuckingEnabled {
                    SettingsFieldRow(title: "Duck to level") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Slider(
                                    value: $settings.audioDuckingLevel,
                                    in: 0.0...0.5,
                                    step: 0.05
                                )
                                Text("\(Int(settings.audioDuckingLevel * 100))%")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                            }

                            SettingsHelpText(
                                "Percentage of current volume to duck to. 0% = mute, 20% = quiet background."
                            )
                        }
                    }

                    SettingsFieldRow(title: "Fade-in duration") {
                        HStack(spacing: 8) {
                            Slider(
                                value: $settings.audioDuckingFadeInDuration,
                                in: 0.3...5.0,
                                step: 0.1
                            )
                            Text(String(format: "%.1fs", settings.audioDuckingFadeInDuration))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }

            SettingsGroup(title: "Shortcut") {
                ToggleSettingRow(
                    title: "Single modifier key",
                    subtitle: "Tap for overlay buffer, hold for live auto-paste.",
                    isOn: Binding(
                        get: { settings.modifierOnlyHotKeyEnabled },
                        set: { newValue in
                            settings.modifierOnlyHotKeyEnabled = newValue
                            viewModel.applyHotKeySettingsChange()
                        }
                    )
                )

                if settings.modifierOnlyHotKeyEnabled {
                    SettingsFieldRow(title: "Modifier key") {
                        Picker("", selection: Binding(
                            get: { settings.modifierOnlyHotKeyModifier },
                            set: { newValue in
                                settings.modifierOnlyHotKeyModifier = newValue
                                viewModel.applyHotKeySettingsChange()
                            }
                        )) {
                            ForEach(ModifierOnlyHotKeyManager.ModifierKey.allCases) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    SettingsFieldRow(title: "Hold delay") {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { settings.modifierOnlyHoldDelay },
                                    set: { newValue in
                                        settings.modifierOnlyHoldDelay = newValue
                                        viewModel.applyHotKeySettingsChange()
                                    }
                                ),
                                in: 0.15...0.8,
                                step: 0.05
                            )
                            Text("\(Int(settings.modifierOnlyHoldDelay * 1000))ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                } else {
                    SettingsFieldRow(title: "Overlay Buffer") {
                        HStack(alignment: .center, spacing: 8) {
                            ShortcutRecorderField(
                                shortcut: overlayBufferShortcutBinding,
                                validationError: $overlayValidationError,
                                fixedWidth: 132
                            )
                            .frame(height: 24, alignment: .leading)

                            Button("Reset") {
                                overlayValidationError = nil
                                viewModel.updateOverlayBufferShortcut(
                                    SettingsStore.defaultDictationShortcut)
                            }
                            .disabled(
                                settings.overlayBufferShortcut == SettingsStore.defaultDictationShortcut)
                        }
                    }

                    if let overlayValidationError {
                        SettingsMessageRow(overlayValidationError, color: .red)
                    }

                    if settings.overlayBufferShortcut == nil {
                        SettingsMessageRow(
                            "Overlay Buffer shortcut is currently disabled.",
                            color: .secondary
                        )
                    }

                    SettingsFieldRow(title: "Live Auto-Paste") {
                        HStack(alignment: .center, spacing: 8) {
                            ShortcutRecorderField(
                                shortcut: livePasteShortcutBinding,
                                validationError: $livePasteValidationError,
                                fixedWidth: 132
                            )
                            .frame(height: 24, alignment: .leading)

                            if settings.livePasteShortcut != nil {
                                Button("Clear") {
                                    livePasteValidationError = nil
                                    viewModel.updateLivePasteShortcut(nil)
                                }
                            }
                        }
                    }

                    if let livePasteValidationError {
                        SettingsMessageRow(livePasteValidationError, color: .red)
                    }

                    if settings.livePasteShortcut == nil {
                        SettingsMessageRow(
                            "Live Auto-Paste shortcut is not set. Record one above to enable.",
                            color: .secondary
                        )
                    }
                }
            }
        }
    }
}

private struct TextProcessingSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    private var isAvailableInCurrentMode: Bool {
        settings.dictationOutputMode == .overlayBuffer
    }

    private var llmPolishingEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.llmPolishingEnabled },
            set: { newValue in
                let wasEnabled = settings.llmPolishingEnabled
                settings.llmPolishingEnabled = newValue

                if newValue, !wasEnabled {
                    viewModel.prepareLLMPolishingPromptAccessIfNeeded()
                }
            }
        )
    }

    var body: some View {
        SettingsPage {
            if !isAvailableInCurrentMode {
                SettingsAvailabilityCard(
                    title: "Unavailable in Live Auto-Paste output mode",
                    message:
                        "Text Processing can't run in Live Auto-Paste output mode. Switch Dictation > Output mode to Overlay Buffer to enable text processing features.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }

            SettingsGroup(title: "Features") {
                ToggleSettingRow(
                    title: "Exact match replacements",
                    subtitle:
                        "Apply exact match replacements using the replacement dictionary during finalization.",
                    isOn: $settings.replacementDictionaryEnabled
                )

                ToggleSettingRow(
                    title: "LLM polishing",
                    subtitle:
                        "Send dictation text to an OpenAI-compatible chat completions server.",
                    isOn: llmPolishingEnabledBinding
                )

                if settings.llmPolishingEnabled {
                    SettingsFieldRow(title: "Endpoint") {
                        TextField(
                            "http://127.0.0.1:8080/v1/chat/completions",
                            text: $settings.llmPolishingEndpointURL
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField(
                            "Required for remote providers",
                            text: $settings.llmPolishingAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField("mlx-community/Qwen3.5-0.8B-8bit", text: $settings.llmPolishingModel)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .disabled(!isAvailableInCurrentMode)
            .opacity(isAvailableInCurrentMode ? 1.0 : 0.5)

            SettingsGroup(title: "Shared Configuration") {
                SettingsFieldRow(title: "Config folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Open Config Folder") {
                            viewModel.openConfigFolder()
                        }

                        SettingsHelpText("Changes apply to the next finalized dictation.")
                    }
                }

                SettingsFieldRow(title: "Included files") {
                    SettingsFileNotes(notes: [
                        SettingsFileNote(
                            name: "replacement_dictionary.toml",
                            description:
                                "Replacements used during finalization."
                        ),
                        SettingsFileNote(
                            name: "llm_system_prompt.toml",
                            description: "System prompt used for LLM polishing."
                        ),
                        SettingsFileNote(
                            name: "llm_user_prompt.toml",
                            description:
                                "User prompt template used for LLM polishing. Remove the {{replacement_dictionary}} placeholder if you do not want to send the dictionary to the LLM."
                        ),
                    ])
                }
            }
            .disabled(!isAvailableInCurrentMode)
            .opacity(isAvailableInCurrentMode ? 1.0 : 0.5)
        }
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(SettingsLayout.pagePadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: SettingsLayout.cardSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsLayout.cardPadding)
            .background {
                RoundedRectangle(
                    cornerRadius: SettingsLayout.cornerRadius,
                    style: .continuous
                )
                .fill(Color(nsColor: .quaternarySystemFill))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: SettingsLayout.cornerRadius,
                        style: .continuous
                    )
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsAvailabilityCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    private let cornerRadius: CGFloat = 16
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .fill(tint.opacity(0.10))
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(tint.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsHelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsFileNote: Identifiable {
    let id = UUID()
    let name: String
    let description: String
}

private struct SettingsFileNotes: View {
    let notes: [SettingsFileNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))

                    Text(note.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsInlineMessage: View {
    let message: String
    let color: Color

    init(_ message: String, color: Color) {
        self.message = message
        self.color = color
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsMessageRow: View {
    let message: String
    let color: Color

    init(_ message: String, color: Color) {
        self.message = message
        self.color = color
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
            Color.clear
                .frame(width: SettingsLayout.labelWidth, height: 1)
            SettingsInlineMessage(message, color: color)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToggleSettingRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                if let subtitle {
                    SettingsHelpText(subtitle)
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
