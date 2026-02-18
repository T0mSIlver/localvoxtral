import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

    private var mlxTranscriptionDelaySecondsBinding: Binding<Double> {
        Binding(
            get: { Double(settings.mlxAudioTranscriptionDelayMilliseconds) / 1000.0 },
            set: { newValue in
                let milliseconds = Int((newValue * 1000.0).rounded())
                settings.mlxAudioTranscriptionDelayMilliseconds = min(max(milliseconds, 0), 3_000)
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
                        Text("Configure connection and dictation defaults.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsSection(title: "Connection") {
                        SettingsField(title: "Backend") {
                            Picker("Backend", selection: $settings.realtimeProvider) {
                                ForEach(SettingsStore.RealtimeProvider.allCases) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

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
                        } else {
                            Text("`mlx-audio` usually runs locally and does not require an API key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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

                                Slider(value: mlxTranscriptionDelaySecondsBinding, in: 0.0 ... 3.0, step: 0.05)

                                Text("How long `mlx-audio` waits for right-context before emitting tokens.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text("Unlike vLLM commit interval, this does not control commit cadence. Commit interval controls how often vLLM finalization is requested.")
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
                .frame(maxWidth: 336, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?
                    .makeKeyAndOrderFront(nil)
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
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
