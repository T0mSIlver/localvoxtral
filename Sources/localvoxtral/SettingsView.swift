import AppKit
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
        .overlay {
            FixedSettingsWindowTitle(title: "localvoxtral Settings")
                .frame(width: 0, height: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FixedSettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleTrackingView {
        let view = TitleTrackingView()
        view.update(title: title)
        return view
    }

    func updateNSView(_ nsView: TitleTrackingView, context: Context) {
        nsView.update(title: title)
    }
}

private final class TitleTrackingView: NSView {
    private var desiredTitle = ""
    private var observedWindow: NSWindow?
    private var titleObservation: NSKeyValueObservation?

    func update(title: String) {
        desiredTitle = title
        attachObservationIfNeeded()
        applyTitle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachObservationIfNeeded()
        applyTitle()
    }

    private func attachObservationIfNeeded() {
        guard let window, window !== observedWindow else { return }

        observedWindow = window
        titleObservation = window.observe(\.title, options: [.new]) { [weak self, weak window] _, _ in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, window.title != self.desiredTitle else { return }
                window.title = self.desiredTitle
            }
        }
    }

    private func applyTitle() {
        guard let window, window.title != desiredTitle else { return }
        window.title = desiredTitle
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
    @Binding var shortcutValidationError: String?

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
            }

            SettingsGroup(title: "Shortcut") {
                SettingsFieldRow(title: "Dictation shortcut") {
                    HStack(alignment: .center, spacing: 8) {
                        ShortcutRecorderField(
                            shortcut: dictationShortcutBinding,
                            validationError: $shortcutValidationError,
                            fixedWidth: 132
                        )
                        .frame(height: 24, alignment: .leading)

                        Button("Reset to Default") {
                            shortcutValidationError = nil
                            viewModel.updateDictationShortcut(
                                SettingsStore.defaultDictationShortcut)
                        }
                        .disabled(
                            settings.dictationShortcut == SettingsStore.defaultDictationShortcut)
                    }
                }

                if let shortcutValidationError {
                    SettingsMessageRow(shortcutValidationError, color: .red)
                }

                if settings.dictationShortcut == nil {
                    SettingsMessageRow(
                        "Global dictation shortcut is currently disabled.",
                        color: .secondary
                    )
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
                    title: "Enable replacement dictionary",
                    subtitle:
                        "Apply exact match replacements during finalization. If LLM polishing is enabled, the dictionary is provided to the LLM for more consistent replacement.",
                    isOn: $settings.replacementDictionaryEnabled
                )

                ToggleSettingRow(
                    title: "Enable LLM polishing",
                    subtitle:
                        "Send dictation text to an OpenAI-compatible chat completions server.",
                    isOn: $settings.llmPolishingEnabled
                )

                if settings.llmPolishingEnabled {
                    SettingsFieldRow(title: "Endpoint") {
                        TextField(
                            "http://127.0.0.1:8000/v1/chat/completions",
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
                        TextField("gpt-4o-mini", text: $settings.llmPolishingModel)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .disabled(!isAvailableInCurrentMode)
            .opacity(isAvailableInCurrentMode ? 1.0 : 0.5)

            SettingsGroup(title: "Shared Configuration") {
                SettingsFieldRow(title: "Config files") {
                    Button("Open Config Folder") {
                        viewModel.openConfigFolder()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SettingsHelpText(
                        "Edit these files in the config folder. Changes apply to the next finalized dictation."
                    )

                    SettingsHelpList(items: [
                        "replacement_dictionary.toml: exact-match replacements used during finalization and shared with LLM polishing when enabled.",
                        "llm_system_prompt.toml: system prompt used for LLM polishing.",
                        "llm_user_prompt.toml: user prompt template used for LLM polishing.",
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

private struct SettingsHelpList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    Text(item)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
