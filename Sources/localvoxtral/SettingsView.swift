import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

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
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(.system(size: 24, weight: .semibold))
                        Text("Configure connection and dictation defaults.")
                            .font(.callout)
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
                            Text("`mlx-audio` performs segmentation server-side, so commit interval is ignored.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
                .frame(maxWidth: 292, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
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
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            content
        }
    }
}
