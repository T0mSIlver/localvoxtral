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
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .semibold))
                }

                SettingsSection(title: "Endpoint Settings") {
                    SettingsField(title: "Provider") {
                        Picker("", selection: $settings.realtimeProvider) {
                            ForEach(SettingsStore.RealtimeProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    SettingsField(title: "Realtime endpoint") {
                        TextField(settings.endpointPlaceholder, text: endpointBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    SettingsField(title: "Model") {
                        TextField(settings.modelPlaceholder, text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    if settings.realtimeProvider == .realtimeAPI {
                        SettingsField(title: "API key") {
                            SecureField("Required for remote providers", text: $settings.apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if settings.realtimeProvider == .realtimeAPI {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Commit interval")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(String(format: "%.2fs", settings.commitIntervalSeconds))
                                    .foregroundStyle(.secondary)
                            }

                            Slider(value: $settings.commitIntervalSeconds, in: 0.1 ... 1.0, step: 0.1)

                            Text("How often finalized transcript chunks are requested from the realtime server.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Transcription delay")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(mlxTranscriptionDelayLabel)
                                    .foregroundStyle(.secondary)
                            }

                            Slider(value: mlxTranscriptionDelaySecondsBinding, in: 0.4 ... 2.0, step: 0.1)

                            Text("How long mlx-audio waits for right-context before emitting tokens.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsSection(title: "Dictation") {
                    SettingsField(title: "Output mode") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $settings.dictationOutputMode) {
                                ForEach(DictationOutputMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text(settings.dictationOutputMode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    SettingsField(title: "Shortcut behavior") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $settings.dictationShortcutMode) {
                                ForEach(DictationShortcutMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text(settings.dictationShortcutMode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ToggleSettingRow(
                        title: "Auto-copy final segment",
                        isOn: $settings.autoCopyEnabled
                    )

                    SettingsField(title: "Dictation shortcut") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 8) {
                                ShortcutRecorderField(
                                    shortcut: dictationShortcutBinding,
                                    validationError: $shortcutValidationError,
                                    fixedWidth: 132
                                )
                                .frame(height: 24, alignment: .leading)

                                Button("Reset to Default") {
                                    shortcutValidationError = nil
                                    viewModel.updateDictationShortcut(SettingsStore.defaultDictationShortcut)
                                }
                                .disabled(settings.dictationShortcut == SettingsStore.defaultDictationShortcut)
                            }
                        }
                    }

                    if let shortcutValidationError {
                        Text(shortcutValidationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if settings.dictationShortcut == nil {
                        Text("Global dictation shortcut is currently disabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }
            }
            .frame(width: 332, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            content
        }
    }
}

private struct ToggleSettingRow: View {
    let title: String
    let subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
