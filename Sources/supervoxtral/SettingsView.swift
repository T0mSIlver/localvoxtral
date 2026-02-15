import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

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
                        SettingsField(title: "Realtime endpoint") {
                            TextField("ws://127.0.0.1:8000/v1/realtime", text: $settings.endpointURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        SettingsField(title: "Model") {
                            TextField("voxtral-mini-latest", text: $settings.modelName)
                                .textFieldStyle(.roundedBorder)
                        }

                        SettingsField(title: "API key") {
                            SecureField("Required for remote providers", text: $settings.apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    SettingsSection(title: "Transcription") {
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
