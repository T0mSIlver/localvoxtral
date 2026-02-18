import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

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
                case .openAICompatible:
                    settings.openAIEndpointURL = newValue
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
                case .openAICompatible:
                    settings.openAIModelName = newValue
                case .mlxAudio:
                    settings.mlxAudioModelName = newValue
                }
            }
        )
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(.system(size: 22, weight: .semibold))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $settings.realtimeProvider) {
                            ForEach(SettingsStore.RealtimeProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsField(title: "Realtime endpoint") {
                            TextField(settings.endpointPlaceholder, text: endpointBinding)
                                .textFieldStyle(.roundedBorder)
                        }

                        SettingsField(title: "Model") {
                            TextField(settings.modelPlaceholder, text: modelBinding)
                                .textFieldStyle(.roundedBorder)
                        }

                        if settings.realtimeProvider == .openAICompatible {
                            SettingsField(title: "API key") {
                                SecureField("Required for remote providers", text: $settings.apiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    SettingsSection(title: "Transcription") {
                        if settings.realtimeProvider == .openAICompatible {
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

                        Toggle(isOn: $settings.autoCopyEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-copy finalized segment")
                                Text("Copy each finalized segment to the clipboard automatically.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
                .frame(maxWidth: 332, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
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
